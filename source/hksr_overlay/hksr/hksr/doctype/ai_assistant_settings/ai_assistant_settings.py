from __future__ import annotations

import re
from urllib.parse import urlsplit

import frappe
from frappe import _
from frappe.model.document import Document

from hksr.ai_assistant.query_plan import HARD_MAX_LIMIT


class AIAssistantSettings(Document):
	def validate(self) -> None:
		self._validate_limits()
		self._validate_allowlist()
		self._validate_configuration()

	def on_update(self) -> None:
		if self.flags.skip_ai_schema_sync or not self.enabled:
			return
		before = self.get_doc_before_save()
		if not before or self._sync_fingerprint() == self._sync_fingerprint(before):
			return
		from hksr.ai_assistant.sync import enqueue_schema_sync

		enqueue_schema_sync(reason="settings-change")

	def _validate_limits(self) -> None:
		try:
			default_limit = int(self.default_result_limit)
			maximum_limit = int(self.maximum_result_limit)
		except (TypeError, ValueError):
			frappe.throw(_("Result limits must be integers."))
		if not 1 <= maximum_limit <= HARD_MAX_LIMIT:
			frappe.throw(_("Maximum Result Limit must be between 1 and {0}.").format(HARD_MAX_LIMIT))
		if not 1 <= default_limit <= maximum_limit:
			frappe.throw(_("Default Result Limit must be between 1 and the configured maximum."))

	def _validate_allowlist(self) -> None:
		names = [row.allowed_doctype for row in self.allowed_doctypes if row.allowed_doctype]
		if len(names) > 50:
			frappe.throw(_("At most 50 DocTypes may be allowlisted."))
		if len(names) != len(set(names)):
			frappe.throw(_("The AI assistant DocType allowlist contains duplicates."))
		for doctype in names:
			meta = frappe.get_meta(doctype)
			if meta.issingle or meta.istable or getattr(meta, "is_virtual", 0):
				frappe.throw(_("DocType {0} is not a normal database-backed DocType.").format(doctype))

	def _validate_configuration(self) -> None:
		if self.webhook_url:
			path = str(self.webhook_url).strip()
			if not re.fullmatch(r"/n8n-webhook/[A-Za-z0-9][A-Za-z0-9_-]{15,127}/chat", path):
				frappe.throw(_("Webhook URL must be a same-origin /n8n-webhook/.../chat path."))
		if self.schema_sync_url:
			parsed = urlsplit(str(self.schema_sync_url))
			if parsed.scheme not in {"http", "https"} or not parsed.hostname or parsed.username or parsed.password:
				frappe.throw(_("Schema Sync URL must be an HTTP(S) URL without embedded credentials."))

		if not self.enabled:
			return
		missing = []
		if not (frappe.conf.get("ai_assistant_site_id") or self.site_identifier):
			missing.append("Site Identifier")
		if not (frappe.conf.get("ai_assistant_webhook_url") or self.webhook_url):
			missing.append("Webhook URL")
		if not (frappe.conf.get("ai_assistant_sync_url") or self.schema_sync_url):
			missing.append("Schema Sync URL")
		try:
			secret = self.get_password("integration_secret", raise_exception=False)
		except TypeError:
			secret = self.get_password("integration_secret")
		if not secret or len(secret) < 32:
			missing.append("Integration Secret (at least 32 characters)")
		if not self.allowed_doctypes:
			missing.append("Allowed DocTypes")
		if missing:
			frappe.throw(_("Configure these fields before enabling the assistant: {0}").format(", ".join(missing)))

	def _sync_fingerprint(self, document=None) -> tuple:
		document = document or self
		return (
			document.site_identifier,
			document.schema_sync_url,
			document.default_result_limit,
			document.maximum_result_limit,
			tuple(sorted(row.allowed_doctype for row in document.allowed_doctypes if row.allowed_doctype)),
		)
