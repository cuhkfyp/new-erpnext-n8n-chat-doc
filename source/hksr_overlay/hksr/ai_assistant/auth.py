"""Short-lived, session-bound browser authentication for the AI assistant."""

from __future__ import annotations

import hashlib
import secrets
import time
from contextlib import contextmanager
from typing import Any

import frappe
from frappe import _

TOKEN_HEADER = "X-AI-Assistant-Token"
SESSION_HEADER = "X-AI-Assistant-Session"
INTEGRATION_HEADER = "X-AI-Assistant-Integration-Key"
TOKEN_KEY_PREFIX = "hksr:ai-assistant:token:"
SESSION_KEY_PREFIX = "hksr:ai-assistant:session:"
DEFAULT_TOKEN_TTL_SECONDS = 8 * 60 * 60
MIN_TOKEN_TTL_SECONDS = 5 * 60
MAX_TOKEN_TTL_SECONDS = 24 * 60 * 60


def require_authenticated_user() -> str:
	user = getattr(getattr(frappe, "session", None), "user", None)
	if not user or user == "Guest":
		frappe.throw(_("Authentication is required."), frappe.AuthenticationError)
	return user


def issue_browser_token(site_id: str) -> dict[str, Any]:
	"""Create an opaque token that is valid only with the issuing Frappe session."""
	user = require_authenticated_user()
	frappe_sid = _current_session_sid()
	session_digest = _sha256(frappe_sid)
	ttl = _token_ttl_seconds()
	chat_session_id = _get_or_create_chat_session_id(session_digest, ttl)
	token = secrets.token_urlsafe(32)
	token_digest = _sha256(token)

	frappe.cache.set_value(
		f"{TOKEN_KEY_PREFIX}{token_digest}",
		{
			"user": user,
			"frappe_sid": frappe_sid,
			"session_digest": session_digest,
			"chat_session_id": chat_session_id,
			"site_id": site_id,
			"issued_at": int(time.time()),
		},
		expires_in_sec=ttl,
	)
	return {
		"token": token,
		"session_id": chat_session_id,
		"expires_in": ttl,
	}


def validate_browser_token(token: str | None = None, session_id: str | None = None) -> dict[str, Any]:
	"""Validate an opaque bearer token against its still-active issuing session."""
	token = token or _request_header(TOKEN_HEADER)
	if not token or not isinstance(token, str) or len(token) > 256:
		frappe.throw(_("The AI assistant session token is missing or invalid."), frappe.AuthenticationError)

	stored = frappe.cache.get_value(f"{TOKEN_KEY_PREFIX}{_sha256(token)}")
	if not isinstance(stored, dict):
		frappe.throw(_("The AI assistant session has expired."), frappe.AuthenticationError)

	user = str(stored.get("user") or "")
	frappe_sid = str(stored.get("frappe_sid") or "")
	if not user or user == "Guest" or not frappe_sid or not secrets.compare_digest(
		str(stored.get("session_digest") or ""), _sha256(frappe_sid)
	):
		frappe.throw(_("The AI assistant session is invalid."), frappe.AuthenticationError)
	_validate_active_frappe_session(frappe_sid, user)

	request_user = getattr(getattr(frappe, "session", None), "user", None)
	if request_user and request_user != "Guest":
		if not (
			secrets.compare_digest(user, str(request_user))
			and secrets.compare_digest(str(stored.get("session_digest") or ""), _sha256(_current_session_sid()))
		):
			frappe.throw(_("The AI assistant session does not match this browser session."), frappe.AuthenticationError)

	request_session_id = session_id or _request_header(SESSION_HEADER)
	if not request_session_id or len(request_session_id) > 256 or not secrets.compare_digest(
		str(stored.get("chat_session_id") or ""), request_session_id
	):
		frappe.throw(_("The AI assistant chat session is invalid."), frappe.AuthenticationError)

	return stored


@contextmanager
def browser_user_context(user: str):
	"""Run permission checks as the token owner without creating or copying a login session."""
	require_user = str(user or "")
	if not require_user or require_user == "Guest":
		frappe.throw(_("The AI assistant user is invalid."), frappe.AuthenticationError)

	session = frappe.session
	previous_user = session.user
	if previous_user == require_user:
		yield
		return

	previous_user_perms = getattr(frappe.local, "user_perms", None)
	previous_role_permissions = getattr(frappe.local, "role_permissions", None)
	previous_local_cache = getattr(frappe.local, "cache", None)
	try:
		session.user = require_user
		frappe.local.user_perms = None
		frappe.local.role_permissions = {}
		frappe.local.cache = {}
		yield
	finally:
		session.user = previous_user
		frappe.local.user_perms = previous_user_perms
		frappe.local.role_permissions = previous_role_permissions
		frappe.local.cache = previous_local_cache


def validate_integration_key() -> None:
	"""Authenticate n8n schema-sync calls without storing plaintext in source."""
	provided = _request_header(INTEGRATION_HEADER)
	settings = frappe.get_single("AI Assistant Settings")
	try:
		expected = settings.get_password("integration_secret", raise_exception=False)
	except TypeError:
		expected = settings.get_password("integration_secret")

	if not provided or not expected or not secrets.compare_digest(str(provided), str(expected)):
		frappe.throw(_("Invalid AI assistant integration credential."), frappe.AuthenticationError)


def get_request_header(name: str) -> str | None:
	return _request_header(name)


def _get_or_create_chat_session_id(session_digest: str, ttl: int) -> str:
	key = f"{SESSION_KEY_PREFIX}{session_digest}"
	chat_session_id = frappe.cache.get_value(key)
	if not chat_session_id:
		chat_session_id = secrets.token_urlsafe(24)
	frappe.cache.set_value(key, chat_session_id, expires_in_sec=ttl)
	return str(chat_session_id)


def _current_session_sid() -> str:
	sid = getattr(getattr(frappe, "session", None), "sid", None)
	request = getattr(getattr(frappe, "local", None), "request", None)
	if not sid and request is not None:
		sid = request.cookies.get("sid")
	if not sid:
		frappe.throw(_("A valid Frappe browser session is required."), frappe.AuthenticationError)
	return str(sid)


def _validate_active_frappe_session(sid: str, user: str) -> None:
	from frappe.sessions import get_expired_threshold

	sessions = frappe.qb.DocType("Sessions")
	active_users = (
		frappe.qb.from_(sessions)
		.select(sessions.user)
		.where(sessions.sid == sid)
		.where(sessions.user == user)
		.where(sessions.status == "Active")
		.where(sessions.lastupdate > get_expired_threshold())
		.limit(1)
	).run(pluck=True)
	active_user = active_users[0] if active_users else None
	user_enabled = frappe.get_cached_value("User", user, "enabled")
	if not active_user or not user_enabled or not secrets.compare_digest(str(active_user), user):
		frappe.throw(_("The ERPNext browser session has expired."), frappe.AuthenticationError)


def _request_header(name: str) -> str | None:
	request = getattr(getattr(frappe, "local", None), "request", None)
	if request is None:
		return None
	value = request.headers.get(name)
	return str(value) if value is not None else None


def _token_ttl_seconds() -> int:
	configured = frappe.conf.get("ai_assistant_token_ttl_seconds") or DEFAULT_TOKEN_TTL_SECONDS
	try:
		value = int(configured)
	except (TypeError, ValueError):
		value = DEFAULT_TOKEN_TTL_SECONDS
	return max(MIN_TOKEN_TTL_SECONDS, min(value, MAX_TOKEN_TTL_SECONDS))


def _sha256(value: str) -> str:
	return hashlib.sha256(value.encode("utf-8")).hexdigest()
