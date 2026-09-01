from __future__ import annotations

import frappe
from frappe.tests.utils import FrappeTestCase
from unittest.mock import patch

from hksr.ai_assistant.api import _validate_same_origin_webhook_path
from hksr.ai_assistant.query_plan import QueryPlanValidationError, execute_query_plan, validate_query_plan
from hksr.ai_assistant.schema import build_schema_catalog


class TestAIAssistantQueryPlan(FrappeTestCase):
	@classmethod
	def setUpClass(cls):
		super().setUpClass()
		frappe.set_user("Administrator")
		cls.settings = frappe.get_single("AI Assistant Settings")
		cls.allowed = [row.allowed_doctype for row in cls.settings.allowed_doctypes if row.allowed_doctype]

	def base_plan(self):
		return {
			"version": "1",
			"doctype": self.allowed[0],
			"fields": ["name"],
			"filters": [],
			"order_by": [{"field": "modified", "direction": "desc"}],
			"offset": 0,
			"limit": 1,
			"aggregates": [],
			"group_by": [],
		}

	def test_valid_list_executes_through_get_list(self):
		result = execute_query_plan(self.base_plan())
		self.assertEqual(result["doctype"], self.allowed[0])
		self.assertLessEqual(len(result["rows"]), 1)
		self.assertEqual(set(result["rows"][0]) if result["rows"] else {"name"}, {"name"})

	def test_count_aggregate_is_generated_server_side(self):
		plan = self.base_plan()
		plan["fields"] = []
		plan["order_by"] = []
		plan["aggregates"] = [{"function": "count", "field": "*"}]
		validated = validate_query_plan(plan)
		self.assertEqual(validated.aggregates, [("count", "*")])
		result = execute_query_plan(plan)
		self.assertEqual(result["aggregates"][0], {"alias": "aggregate_0", "function": "count", "field": "*"})
		self.assertLessEqual(len(result["rows"]), 1)
		if result["rows"]:
			self.assertIn("aggregate_0", result["rows"][0])

	def test_grouped_count_executes_with_validated_fields(self):
		plan = self.base_plan()
		plan["fields"] = ["owner"]
		plan["order_by"] = [{"field": "owner", "direction": "asc"}]
		plan["aggregates"] = [{"function": "count", "field": "*"}]
		plan["group_by"] = ["owner"]
		result = execute_query_plan(plan)
		self.assertLessEqual(len(result["rows"]), 1)
		if result["rows"]:
			self.assertEqual(set(result["rows"][0]), {"owner", "aggregate_0"})

	def test_raw_sql_and_write_keys_are_rejected(self):
		for key in ("sql", "query", "update", "delete"):
			plan = self.base_plan()
			plan[key] = "SELECT * FROM tabUser"
			with self.assertRaises(QueryPlanValidationError):
				validate_query_plan(plan)

	def test_injection_field_operator_and_limit_are_rejected(self):
		plans = []
		field_plan = self.base_plan()
		field_plan["fields"] = ["name; DROP TABLE tabUser"]
		plans.append(field_plan)

		operator_plan = self.base_plan()
		operator_plan["filters"] = [{"field": "name", "operator": "= 1 OR 1=1", "value": "x"}]
		plans.append(operator_plan)

		limit_plan = self.base_plan()
		limit_plan["limit"] = 101
		plans.append(limit_plan)

		for plan in plans:
			with self.assertRaises((QueryPlanValidationError, frappe.PermissionError)):
				validate_query_plan(plan)

	def test_non_allowlisted_doctype_is_rejected(self):
		plan = self.base_plan()
		plan["doctype"] = "User"
		with self.assertRaises(frappe.PermissionError):
			validate_query_plan(plan)

	def test_schema_catalog_is_stable_and_schema_only(self):
		with patch("hksr.ai_assistant.schema.get_site_id", return_value="automated-test"):
			first = build_schema_catalog()
			second = build_schema_catalog()
		self.assertTrue(first["complete"])
		self.assertEqual(first["catalog_hash"], second["catalog_hash"])
		self.assertEqual(first["doctype_count"], len(self.allowed))
		serialized = frappe.as_json(first)
		self.assertNotIn('"records"', serialized)
		self.assertNotIn('"rows"', serialized)

	def test_webhook_path_is_exact_same_origin_and_bounded(self):
		valid = "/n8n-webhook/example-ai-chat-v2-20260901-abcdef12/chat"
		self.assertEqual(_validate_same_origin_webhook_path(valid), valid)
		for invalid in (
			"https://example.invalid/n8n-webhook/abcdefghijklmnop/chat",
			"/n8n-webhook/short/chat",
			"/n8n-webhook/../../abcdefghijklmnop/chat",
			"/n8n-webhook/abcdefghijklmnop/chat?debug=1",
			"/n8n-webhook/abcdefghijklmnop/extra/chat",
		):
			with self.assertRaises(frappe.ValidationError):
				_validate_same_origin_webhook_path(invalid)
