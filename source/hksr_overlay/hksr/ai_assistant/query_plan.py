"""Strict QueryPlanV1 validation and permission-aware execution."""

from __future__ import annotations

import json
import re
from dataclasses import dataclass
from typing import Any

import frappe
from frappe import _
from frappe.model import get_permitted_fields

QUERY_PLAN_VERSION = "1"
HARD_MAX_LIMIT = 100
DEFAULT_RESULT_LIMIT = 20
MAX_OFFSET = 10_000
MAX_PAYLOAD_BYTES = 32_768
MAX_FIELDS = 25
MAX_FILTERS = 20
MAX_SORT_FIELDS = 3
MAX_GROUP_FIELDS = 3
MAX_AGGREGATES = 5
MAX_IN_VALUES = 100
MAX_STRING_VALUE_LENGTH = 2_048
FIELDNAME_RE = re.compile(r"^[A-Za-z0-9_]+$")

ALLOWED_TOP_LEVEL_KEYS = {
	"version",
	"doctype",
	"fields",
	"filters",
	"order_by",
	"offset",
	"limit",
	"aggregates",
	"group_by",
}
ALLOWED_FILTER_KEYS = {"field", "operator", "value"}
ALLOWED_SORT_KEYS = {"field", "direction"}
ALLOWED_AGGREGATE_KEYS = {"function", "field"}
ALLOWED_OPERATORS = {"=", "!=", ">", ">=", "<", "<=", "in", "not in", "like", "not like", "between", "is"}
AGGREGATE_FUNCTIONS = {
	"count": "count",
	"sum": "sum",
	"average": "avg",
	"minimum": "min",
	"maximum": "max",
}
NUMERIC_FIELDTYPES = {"Currency", "Float", "Int", "Percent", "Duration"}
BLOCKED_FIELDTYPES = {
	"Password",
	"Attach",
	"Attach Image",
	"HTML",
	"HTML Editor",
	"Code",
	"Text Editor",
	"Table",
	"Table MultiSelect",
	"Section Break",
	"Column Break",
	"Tab Break",
	"Button",
	"Image",
	"Fold",
	"Heading",
}
DEFAULT_FIELD_TYPES = {
	"name": "Data",
	"owner": "Link",
	"creation": "Datetime",
	"modified": "Datetime",
	"modified_by": "Link",
	"docstatus": "Int",
	"idx": "Int",
}


class QueryPlanValidationError(frappe.ValidationError):
	pass


@dataclass(frozen=True)
class ValidatedPlan:
	doctype: str
	fields: list[str]
	filters: list[list[Any]]
	order_by: list[tuple[str, str]]
	offset: int
	limit: int
	aggregates: list[tuple[str, str]]
	group_by: list[str]


def execute_query_plan(payload: str | dict[str, Any], user: str | None = None) -> dict[str, Any]:
	permission_user = user or frappe.session.user
	plan = validate_query_plan(payload, user=permission_user)
	query_fields, aggregate_metadata = _build_query_fields(plan)
	order_by = ", ".join(f"{field} {direction}" for field, direction in plan.order_by) or None
	group_by = ", ".join(plan.group_by) or None
	fetch_limit = plan.limit + 1
	if plan.aggregates and not plan.group_by:
		fetch_limit = 1

	rows = frappe.get_list(
		plan.doctype,
		fields=query_fields,
		filters=plan.filters,
		order_by=order_by,
		group_by=group_by,
		limit_start=plan.offset,
		limit_page_length=fetch_limit,
		as_list=False,
		user=permission_user,
	)
	truncated = len(rows) > plan.limit
	if truncated:
		rows = rows[: plan.limit]

	return {
		"version": QUERY_PLAN_VERSION,
		"doctype": plan.doctype,
		"rows": rows,
		"returned": len(rows),
		"offset": plan.offset,
		"limit": plan.limit,
		"truncated": truncated,
		"aggregates": aggregate_metadata,
	}


def validate_query_plan(payload: str | dict[str, Any], user: str | None = None) -> ValidatedPlan:
	permission_user = user or frappe.session.user
	plan = _parse_payload(payload)
	_unknown_keys(plan, ALLOWED_TOP_LEVEL_KEYS, "query plan")

	if str(plan.get("version") or "") != QUERY_PLAN_VERSION:
		fail(_("Only QueryPlanV1 is supported."))

	doctype = plan.get("doctype")
	if not isinstance(doctype, str) or not doctype or len(doctype) > 140:
		fail(_("A valid DocType is required."))
	if doctype not in get_allowed_doctypes():
		fail(_("DocType {0} is not enabled for the AI assistant.").format(doctype), frappe.PermissionError)

	meta = frappe.get_meta(doctype)
	if meta.issingle or meta.istable or getattr(meta, "is_virtual", 0):
		fail(_("This DocType cannot be queried by the AI assistant."))
	if not frappe.has_permission(doctype, ptype="read", user=permission_user):
		fail(_("You do not have read permission for this DocType."), frappe.PermissionError)

	permitted = set(get_permitted_fields(doctype, user=permission_user, permission_type="read"))
	queryable_types = _queryable_field_types(meta)
	queryable = set(queryable_types) & permitted

	default_fields = [] if plan.get("aggregates") else ["name"]
	fields = _validate_fields(plan.get("fields", default_fields), "fields", queryable, MAX_FIELDS)
	filters = _validate_filters(plan.get("filters", []), queryable)
	group_by = _validate_fields(plan.get("group_by", []), "group_by", queryable, MAX_GROUP_FIELDS)
	aggregates = _validate_aggregates(plan.get("aggregates", []), queryable, queryable_types)
	order_by = _validate_order_by(plan.get("order_by", []), queryable)

	if group_by and not aggregates:
		fail(_("group_by requires at least one aggregate."))
	if aggregates:
		if fields and fields != group_by:
			fail(_("Aggregate queries may select only their group_by fields."))
		for field, _direction in order_by:
			if field not in group_by:
				fail(_("Aggregate queries may sort only by group_by fields."))
	else:
		group_by = []

	settings = frappe.get_single("AI Assistant Settings")
	default_limit = _bounded_int(settings.default_result_limit, DEFAULT_RESULT_LIMIT, 1, HARD_MAX_LIMIT)
	configured_max = _bounded_int(settings.maximum_result_limit, HARD_MAX_LIMIT, 1, HARD_MAX_LIMIT)
	limit = _strict_int(plan.get("limit", default_limit), "limit", 1, configured_max)
	offset = _strict_int(plan.get("offset", 0), "offset", 0, MAX_OFFSET)

	return ValidatedPlan(
		doctype=doctype,
		fields=fields,
		filters=filters,
		order_by=order_by,
		offset=offset,
		limit=limit,
		aggregates=aggregates,
		group_by=group_by,
	)


def get_allowed_doctypes() -> set[str]:
	settings = frappe.get_single("AI Assistant Settings")
	return {row.allowed_doctype for row in settings.allowed_doctypes if row.allowed_doctype}


def _parse_payload(payload: str | dict[str, Any]) -> dict[str, Any]:
	if isinstance(payload, str):
		if len(payload.encode("utf-8")) > MAX_PAYLOAD_BYTES:
			fail(_("The query plan is too large."))
		try:
			payload = json.loads(payload)
		except (TypeError, ValueError):
			fail(_("The query plan must be valid JSON."))
	if not isinstance(payload, dict):
		fail(_("The query plan must be a JSON object."))
	return payload


def _validate_fields(value: Any, label: str, queryable: set[str], maximum: int) -> list[str]:
	if not isinstance(value, list) or len(value) > maximum:
		fail(_("{0} must be a list with at most {1} entries.").format(label, maximum))
	result: list[str] = []
	for field in value:
		_validate_field(field, queryable)
		if field in result:
			fail(_("Duplicate field {0} is not allowed.").format(field))
		result.append(field)
	return result


def _validate_filters(value: Any, queryable: set[str]) -> list[list[Any]]:
	if not isinstance(value, list) or len(value) > MAX_FILTERS:
		fail(_("filters must be a list with at most {0} entries.").format(MAX_FILTERS))
	result: list[list[Any]] = []
	for item in value:
		if not isinstance(item, dict):
			fail(_("Each filter must be an object."))
		_unknown_keys(item, ALLOWED_FILTER_KEYS, "filter")
		if set(item) != ALLOWED_FILTER_KEYS:
			fail(_("Each filter requires field, operator, and value."))
		field = item["field"]
		operator = str(item["operator"]).lower().strip()
		_validate_field(field, queryable)
		if operator not in ALLOWED_OPERATORS:
			fail(_("Filter operator {0} is not allowed.").format(operator))
		filter_value = _validate_filter_value(operator, item["value"])
		result.append([field, operator, filter_value])
	return result


def _validate_filter_value(operator: str, value: Any) -> Any:
	if operator in {"in", "not in"}:
		if not isinstance(value, list) or not value or len(value) > MAX_IN_VALUES:
			fail(_("in and not in require a non-empty bounded list."))
		return [_validate_scalar(item) for item in value]
	if operator == "between":
		if not isinstance(value, list) or len(value) != 2:
			fail(_("between requires exactly two values."))
		return [_validate_scalar(item) for item in value]
	if operator == "is":
		if not isinstance(value, str) or value.lower() not in {"set", "not set"}:
			fail(_("is accepts only set or not set."))
		return value.lower()
	return _validate_scalar(value)


def _validate_scalar(value: Any) -> Any:
	if value is None or isinstance(value, (bool, int, float)):
		return value
	if isinstance(value, str) and len(value) <= MAX_STRING_VALUE_LENGTH:
		return value
	fail(_("Filter values must be bounded scalar JSON values."))


def _validate_order_by(value: Any, queryable: set[str]) -> list[tuple[str, str]]:
	if not isinstance(value, list) or len(value) > MAX_SORT_FIELDS:
		fail(_("order_by must be a list with at most {0} entries.").format(MAX_SORT_FIELDS))
	result: list[tuple[str, str]] = []
	for item in value:
		if not isinstance(item, dict):
			fail(_("Each order_by entry must be an object."))
		_unknown_keys(item, ALLOWED_SORT_KEYS, "order_by entry")
		if set(item) != ALLOWED_SORT_KEYS:
			fail(_("Each order_by entry requires field and direction."))
		field = item["field"]
		direction = str(item["direction"]).lower().strip()
		_validate_field(field, queryable)
		if direction not in {"asc", "desc"}:
			fail(_("Sort direction must be asc or desc."))
		result.append((field, direction))
	return result


def _validate_aggregates(value: Any, queryable: set[str], field_types: dict[str, str]) -> list[tuple[str, str]]:
	if not isinstance(value, list) or len(value) > MAX_AGGREGATES:
		fail(_("aggregates must be a list with at most {0} entries.").format(MAX_AGGREGATES))
	result: list[tuple[str, str]] = []
	for item in value:
		if not isinstance(item, dict):
			fail(_("Each aggregate must be an object."))
		_unknown_keys(item, ALLOWED_AGGREGATE_KEYS, "aggregate")
		if set(item) != ALLOWED_AGGREGATE_KEYS:
			fail(_("Each aggregate requires function and field."))
		function = str(item["function"]).lower().strip()
		field = item["field"]
		if function not in AGGREGATE_FUNCTIONS:
			fail(_("Aggregate function {0} is not allowed.").format(function))
		if function == "count" and field == "*":
			pass
		else:
			_validate_field(field, queryable)
		if function in {"sum", "average"} and field_types.get(field) not in NUMERIC_FIELDTYPES:
			fail(_("{0} requires a numeric field.").format(function))
		result.append((function, field))
	return result


def _validate_field(field: Any, queryable: set[str]) -> None:
	if not isinstance(field, str) or not FIELDNAME_RE.fullmatch(field) or field not in queryable:
		fail(_("Field {0} is not available or permitted.").format(field), frappe.PermissionError)


def _queryable_field_types(meta: Any) -> dict[str, str]:
	valid_columns = set(meta.get_valid_columns())
	result = {
		field: fieldtype
		for field, fieldtype in DEFAULT_FIELD_TYPES.items()
		if field in valid_columns
	}
	for df in meta.fields:
		if (
			df.fieldname in valid_columns
			and not getattr(df, "virtual", 0)
			and df.fieldtype not in BLOCKED_FIELDTYPES
		):
			result[df.fieldname] = df.fieldtype
	return result


def _build_query_fields(plan: ValidatedPlan) -> tuple[list[str], list[dict[str, str]]]:
	if not plan.aggregates:
		return plan.fields, []
	fields = list(plan.group_by)
	metadata: list[dict[str, str]] = []
	for index, (function, field) in enumerate(plan.aggregates):
		alias = f"aggregate_{index}"
		sql_function = AGGREGATE_FUNCTIONS[function]
		fields.append(f"{sql_function}({field}) as {alias}")
		metadata.append({"alias": alias, "function": function, "field": field})
	return fields, metadata


def _unknown_keys(value: dict[str, Any], allowed: set[str], label: str) -> None:
	unknown = sorted(set(value) - allowed)
	if unknown:
		fail(_("Unsupported keys in {0}: {1}").format(label, ", ".join(unknown)))


def _strict_int(value: Any, label: str, minimum: int, maximum: int) -> int:
	if isinstance(value, bool) or not isinstance(value, int) or not minimum <= value <= maximum:
		fail(_("{0} must be an integer between {1} and {2}.").format(label, minimum, maximum))
	return value


def _bounded_int(value: Any, default: int, minimum: int, maximum: int) -> int:
	try:
		parsed = int(value)
	except (TypeError, ValueError):
		parsed = default
	return max(minimum, min(parsed, maximum))


def fail(message: str, exception: type[Exception] = QueryPlanValidationError) -> None:
	frappe.throw(message, exception)
