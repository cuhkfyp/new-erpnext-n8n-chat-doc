"""Queue and trigger non-blocking n8n schema synchronization."""

from __future__ import annotations

from typing import Any

import frappe
import requests
from frappe.utils import now_datetime

from hksr.ai_assistant.auth import INTEGRATION_HEADER
from hksr.ai_assistant.schema import get_site_id

DEFAULT_ALLOWLIST = ("Example Master", "Example Registration", "Example Reporting View")
SYNC_TIMEOUT_SECONDS = 15


def after_migrate() -> None:
	"""Seed settings and queue sync without ever failing a migration."""
	try:
		ensure_settings_defaults()
		enqueue_schema_sync(reason="after_migrate")
	except Exception:
		try:
			frappe.log_error(title="AI Assistant after_migrate sync enqueue failed", message=frappe.get_traceback())
		except Exception:
			# The after_migrate integration must never turn a sync/Redis/logging outage
			# into a failed ERPNext deployment.
			pass


def nightly_schema_sync() -> None:
	enqueue_schema_sync(reason="nightly-02:30-Asia/Hong_Kong")


def ensure_settings_defaults() -> None:
	settings = frappe.get_single("AI Assistant Settings")
	changed = False
	if not settings.defaults_seeded:
		existing = {row.allowed_doctype for row in settings.allowed_doctypes if row.allowed_doctype}
		missing_defaults = []
		for doctype in DEFAULT_ALLOWLIST:
			if not frappe.db.exists("DocType", doctype):
				missing_defaults.append(doctype)
			elif doctype not in existing:
				settings.append("allowed_doctypes", {"allowed_doctype": doctype})
		settings.defaults_seeded = 1
		if missing_defaults:
			settings.last_sync_status = "Error"
			settings.last_sync_error = (
				"Default allowlist entries are not installed Frappe DocTypes and were not enabled: "
				+ ", ".join(missing_defaults)
			)
		changed = True
	if not settings.default_result_limit:
		settings.default_result_limit = 20
		changed = True
	if not settings.maximum_result_limit:
		settings.maximum_result_limit = 100
		changed = True
	if changed:
		settings.flags.skip_ai_schema_sync = True
		settings.save(ignore_permissions=True)


def enqueue_schema_sync(reason: str) -> dict[str, Any]:
	settings = frappe.get_single("AI Assistant Settings")
	if not settings.enabled:
		return {"queued": False, "reason": "disabled"}

	frappe.db.set_single_value("AI Assistant Settings", "last_sync_status", "Queued")
	frappe.db.set_single_value("AI Assistant Settings", "last_sync_error", "")
	job = frappe.enqueue(
		"hksr.ai_assistant.sync.trigger_schema_sync",
		queue="short",
		enqueue_after_commit=True,
		job_id=f"ai-schema-sync::{get_site_id(settings)}",
		deduplicate=True,
		reason=reason,
	)
	return {"queued": True, "job_id": getattr(job, "id", None), "reason": reason}


def trigger_schema_sync(reason: str = "manual") -> dict[str, Any]:
	settings = frappe.get_single("AI Assistant Settings")
	if not settings.enabled:
		return {"triggered": False, "reason": "disabled"}

	sync_url = frappe.conf.get("ai_assistant_sync_url") or settings.schema_sync_url
	try:
		integration_secret = settings.get_password("integration_secret", raise_exception=False)
	except TypeError:
		integration_secret = settings.get_password("integration_secret")
	if not sync_url or not integration_secret:
		message = "Schema sync URL or integration credential is not configured."
		_record_trigger_error(message)
		raise frappe.ValidationError(message)

	frappe.db.set_single_value("AI Assistant Settings", "last_sync_status", "Running")
	frappe.db.set_single_value("AI Assistant Settings", "last_sync_started_at", now_datetime())
	frappe.db.commit()

	try:
		response = requests.post(
			str(sync_url),
			headers={INTEGRATION_HEADER: str(integration_secret), "Content-Type": "application/json"},
			json={"site_id": get_site_id(settings), "reason": reason},
			timeout=SYNC_TIMEOUT_SECONDS,
		)
		response.raise_for_status()
	except Exception as exc:
		message = f"Unable to trigger n8n schema sync: {str(exc)[:1_500]}"
		_record_trigger_error(message)
		raise
	return {"triggered": True, "reason": reason, "status_code": response.status_code}


def record_sync_result(result: dict[str, Any]) -> dict[str, Any]:
	status = str(result.get("status") or "").title()
	if status not in {"Success", "Drift", "Error"}:
		raise frappe.ValidationError("Sync result status must be Success, Drift, or Error.")

	values = {
		"last_sync_status": status,
		"last_sync_completed_at": now_datetime(),
		"last_sync_catalog_hash": _bounded_text(result.get("catalog_hash"), 64),
		"last_sync_doctype_count": _bounded_nonnegative_int(result.get("doctype_count")),
		"last_sync_chunk_count": _bounded_nonnegative_int(result.get("chunk_count")),
		"last_sync_changed_count": _bounded_nonnegative_int(result.get("changed_count")),
		"last_sync_deleted_count": _bounded_nonnegative_int(result.get("deleted_count")),
		"last_sync_error": _bounded_text(result.get("error"), 4_000),
	}
	for fieldname, value in values.items():
		frappe.db.set_single_value("AI Assistant Settings", fieldname, value)

	if status == "Error":
		frappe.log_error(title="AI Assistant schema sync failed", message=values["last_sync_error"] or "Unknown error")
	return {"recorded": True, "status": status}


def _record_trigger_error(message: str) -> None:
	frappe.db.set_single_value("AI Assistant Settings", "last_sync_status", "Error")
	frappe.db.set_single_value("AI Assistant Settings", "last_sync_completed_at", now_datetime())
	frappe.db.set_single_value("AI Assistant Settings", "last_sync_error", message[:4_000])
	frappe.db.commit()
	frappe.log_error(title="AI Assistant schema sync trigger failed", message=message[:4_000])


def _bounded_nonnegative_int(value: Any) -> int:
	try:
		return max(0, min(int(value or 0), 1_000_000_000))
	except (TypeError, ValueError):
		return 0


def _bounded_text(value: Any, maximum: int) -> str:
	return str(value or "")[:maximum]
