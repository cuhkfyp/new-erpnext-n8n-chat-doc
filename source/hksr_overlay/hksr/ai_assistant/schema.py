"""Build a deterministic schema-only catalog for incremental RAG indexing."""

from __future__ import annotations

import hashlib
import json
import re
from typing import Any

import frappe

from hksr.ai_assistant.query_plan import BLOCKED_FIELDTYPES, DEFAULT_FIELD_TYPES

SCHEMA_CATALOG_VERSION = "1"
FIELDS_PER_CHUNK = 20


def build_schema_catalog() -> dict[str, Any]:
	settings = frappe.get_single("AI Assistant Settings")
	site_id = get_site_id(settings)
	requested_doctypes = sorted(
		{row.allowed_doctype for row in settings.allowed_doctypes if row.allowed_doctype},
		key=str.casefold,
	)
	doctypes: list[dict[str, Any]] = []
	errors: list[dict[str, str]] = []

	for doctype in requested_doctypes:
		try:
			doctypes.append(_build_doctype_catalog(doctype))
		except Exception as exc:
			errors.append({"doctype": doctype, "error": _safe_error(exc)})

	chunk_fingerprints = [
		{
			"doctype": entry["doctype"],
			"chunk_id": chunk["chunk_id"],
			"content_hash": chunk["content_hash"],
		}
		for entry in doctypes
		for chunk in entry["chunks"]
	]
	return {
		"catalog_version": SCHEMA_CATALOG_VERSION,
		"site_id": site_id,
		"complete": not errors and len(doctypes) == len(requested_doctypes),
		"doctype_count": len(doctypes),
		"chunk_count": len(chunk_fingerprints),
		"catalog_hash": _stable_hash(chunk_fingerprints),
		"doctypes": doctypes,
		"errors": errors,
	}


def get_site_id(settings: Any | None = None) -> str:
	settings = settings or frappe.get_single("AI Assistant Settings")
	site_id = frappe.conf.get("ai_assistant_site_id") or settings.site_identifier
	if not site_id:
		frappe.throw("AI assistant site_identifier is not configured.", frappe.ValidationError)
	if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.:-]{1,139}", str(site_id)):
		frappe.throw("AI assistant site_identifier has an invalid format.", frappe.ValidationError)
	return str(site_id)


def _build_doctype_catalog(doctype: str) -> dict[str, Any]:
	meta = frappe.get_meta(doctype)
	if meta.issingle or meta.istable or getattr(meta, "is_virtual", 0):
		raise frappe.ValidationError("Single, child-table, and virtual DocTypes are not indexable.")

	fields = _normalized_fields(meta)
	overview = {
		"doctype": doctype,
		"label": _normalize_text(meta.get("label") or doctype, 280),
		"module": _normalize_text(meta.module, 140),
		"description": _normalize_text(meta.description, 1_000),
		"is_submittable": bool(meta.is_submittable),
		"title_field": meta.title_field if meta.title_field in {field["fieldname"] for field in fields} else None,
		"field_count": len(fields),
	}
	chunks: list[dict[str, Any]] = []
	chunks.append(_make_chunk(doctype, "overview", overview, _overview_content(overview)))
	for offset in range(0, len(fields), FIELDS_PER_CHUNK):
		field_slice = fields[offset : offset + FIELDS_PER_CHUNK]
		chunk_id = f"fields-{offset // FIELDS_PER_CHUNK + 1:03d}"
		payload = {"doctype": doctype, "fields": field_slice}
		chunks.append(_make_chunk(doctype, chunk_id, payload, _fields_content(doctype, field_slice)))

	return {
		"doctype": doctype,
		"schema_hash": _stable_hash([chunk["content_hash"] for chunk in chunks]),
		"chunks": chunks,
	}


def _normalized_fields(meta: Any) -> list[dict[str, Any]]:
	valid_columns = set(meta.get_valid_columns())
	fields: list[dict[str, Any]] = []
	for index, (fieldname, fieldtype) in enumerate(DEFAULT_FIELD_TYPES.items()):
		if fieldname in valid_columns:
			fields.append(
				{
					"fieldname": fieldname,
					"label": fieldname.replace("_", " ").title(),
					"fieldtype": fieldtype,
					"required": fieldname == "name",
					"read_only": fieldname != "name",
					"options": None,
					"description": "",
					"position": index,
				}
			)

	for df in meta.fields:
		if not df.fieldname or df.fieldname not in valid_columns:
			continue
		if getattr(df, "virtual", 0) or df.fieldtype in BLOCKED_FIELDTYPES:
			continue
		fields.append(
			{
				"fieldname": df.fieldname,
				"label": _normalize_text(df.label or df.fieldname, 280),
				"fieldtype": df.fieldtype,
				"required": bool(df.reqd),
				"read_only": bool(df.read_only),
				"options": _normalized_options(df),
				"description": _normalize_text(df.description, 500),
				"position": int(df.idx or 0) + 100,
			}
		)
	return sorted(fields, key=lambda field: (field["position"], field["fieldname"]))


def _normalized_options(df: Any) -> str | list[str] | None:
	if not df.options:
		return None
	if df.fieldtype in {"Link", "Dynamic Link"}:
		return _normalize_text(df.options, 280)
	if df.fieldtype == "Select":
		return [
			_normalize_text(option, 280)
			for option in str(df.options).splitlines()
			if _normalize_text(option, 280)
		][:100]
	return None


def _make_chunk(doctype: str, chunk_id: str, metadata: dict[str, Any], content: str) -> dict[str, Any]:
	return {
		"chunk_id": chunk_id,
		"content_hash": hashlib.sha256(content.encode("utf-8")).hexdigest(),
		"content": content,
		"metadata": {
			"catalog_version": SCHEMA_CATALOG_VERSION,
			"doctype": doctype,
			"chunk_id": chunk_id,
			"schema": metadata,
		},
	}


def _overview_content(overview: dict[str, Any]) -> str:
	return "\n".join(
		[
			f"ERPNext DocType: {overview['doctype']}",
			f"Label: {overview['label']}",
			f"Module: {overview['module']}",
			f"Description: {overview['description'] or '(none)'}",
			f"Submittable: {'yes' if overview['is_submittable'] else 'no'}",
			f"Title field: {overview['title_field'] or 'name'}",
			f"Queryable schema field count: {overview['field_count']}",
		]
	)


def _fields_content(doctype: str, fields: list[dict[str, Any]]) -> str:
	lines = [f"ERPNext DocType fields: {doctype}"]
	for field in fields:
		options = field["options"]
		if isinstance(options, list):
			options_text = ", ".join(options)
		else:
			options_text = options or ""
		lines.append(
			" | ".join(
				[
					field["fieldname"],
					field["label"],
					field["fieldtype"],
					"required" if field["required"] else "optional",
					"read-only" if field["read_only"] else "readable",
					f"options={options_text}" if options_text else "",
					f"description={field['description']}" if field["description"] else "",
				]
			).rstrip(" |")
		)
	return "\n".join(lines)


def _normalize_text(value: Any, maximum: int) -> str:
	if value is None:
		return ""
	return " ".join(str(value).split())[:maximum]


def _stable_hash(value: Any) -> str:
	canonical = json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
	return hashlib.sha256(canonical.encode("utf-8")).hexdigest()


def _safe_error(exc: Exception) -> str:
	return _normalize_text(str(exc) or exc.__class__.__name__, 500)
