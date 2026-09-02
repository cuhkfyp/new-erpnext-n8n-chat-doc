"""Whitelisted APIs used by the ERPNext widget and shadow n8n workflows."""

from __future__ import annotations

import re
from typing import Any

import frappe
from frappe import _
from frappe.utils import get_first_day, get_last_day, get_system_timezone, nowdate

from hksr.ai_assistant.auth import (
	browser_user_context,
	issue_browser_token,
	validate_browser_token,
	validate_integration_key,
)
from hksr.ai_assistant.query_plan import execute_query_plan as run_query_plan
from hksr.ai_assistant.schema import build_schema_catalog, get_site_id
from hksr.ai_assistant.sync import enqueue_schema_sync, record_sync_result as save_sync_result


@frappe.whitelist()
def bootstrap() -> dict[str, Any]:
	settings = _enabled_settings()
	webhook_url = frappe.conf.get("ai_assistant_webhook_url") or settings.webhook_url
	webhook_url = _validate_same_origin_webhook_path(webhook_url)
	token_data = issue_browser_token(get_site_id(settings))
	return {
		"enabled": True,
		"webhook_url": webhook_url,
		"session_id": token_data["session_id"],
		"token": token_data["token"],
		"expires_in": token_data["expires_in"],
		"site_id": get_site_id(settings),
	}


@frappe.whitelist(allow_guest=True)
def validate_session() -> dict[str, Any]:
	_enabled_settings()
	context = validate_browser_token()
	return {
		"valid": True,
		"session_id": context["chat_session_id"],
		"site_id": context["site_id"],
		"date_context": _server_date_context(),
	}


@frappe.whitelist(allow_guest=True)
def execute_query_plan(query_plan: str | dict[str, Any]) -> dict[str, Any]:
	_enabled_settings()
	context = validate_browser_token()
	with browser_user_context(str(context["user"])):
		return run_query_plan(query_plan, user=str(context["user"]))


@frappe.whitelist(allow_guest=True)
def schema_catalog() -> dict[str, Any]:
	validate_integration_key()
	_enabled_settings()
	return build_schema_catalog()


@frappe.whitelist(allow_guest=True)
def record_sync_result(result: str | dict[str, Any]) -> dict[str, Any]:
	validate_integration_key()
	if isinstance(result, str):
		result = frappe.parse_json(result)
	if not isinstance(result, dict):
		frappe.throw(_("Sync result must be a JSON object."), frappe.ValidationError)
	return save_sync_result(result)


@frappe.whitelist()
def request_schema_sync() -> dict[str, Any]:
	frappe.only_for("System Manager")
	return enqueue_schema_sync(reason=f"manual:{frappe.session.user}")


def _enabled_settings() -> Any:
	settings = frappe.get_single("AI Assistant Settings")
	if not settings.enabled:
		frappe.throw(_("The ERPNext AI assistant is disabled."), frappe.PermissionError)
	return settings


def _server_date_context() -> dict[str, Any]:
	"""Return non-user-controlled calendar anchors for relative-date questions."""
	current_date = nowdate()
	current_year = int(current_date[:4])
	return {
		"current_date": current_date,
		"current_year": current_year,
		"current_year_start": f"{current_year:04d}-01-01",
		"current_year_end": f"{current_year:04d}-12-31",
		"current_month_start": get_first_day(current_date).isoformat(),
		"current_month_end": get_last_day(current_date).isoformat(),
		"time_zone": get_system_timezone(),
	}


def _validate_same_origin_webhook_path(value: Any) -> str:
	path = str(value or "").strip()
	if not re.fullmatch(r"/n8n-webhook/[A-Za-z0-9][A-Za-z0-9_-]{15,127}/chat", path):
		frappe.throw(_("The AI assistant webhook path is invalid."))
	return path
