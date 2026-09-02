"""User-isolated, Redis-backed visible chat history for the AI assistant."""

from __future__ import annotations

import hashlib
import hmac
import json
from typing import Any
from urllib.parse import urlparse

import frappe
from frappe import _
from redis import Redis
from redis.exceptions import RedisError

HISTORY_KEY_PREFIX = "u2_"
DEFAULT_HISTORY_TTL_SECONDS = 8 * 60 * 60
MAX_VISIBLE_HISTORY_MESSAGES = 100
MAX_MIGRATED_HISTORY_MESSAGES = 200
MAX_VISIBLE_MESSAGE_CHARS = 50_000
MAX_VISIBLE_HISTORY_CHARS = 500_000

_MIGRATE_HISTORY_LUA = """
local source = KEYS[1]
local target = KEYS[2]
local default_ttl = tonumber(ARGV[1])
local maximum = tonumber(ARGV[2])

if source == target or redis.call('EXISTS', source) == 0 then
  return redis.call('LLEN', target)
end

local source_ttl = redis.call('PTTL', source)
local target_ttl = redis.call('PTTL', target)
local source_values = redis.call('LRANGE', source, 0, -1)
local target_values = redis.call('LRANGE', target, 0, -1)
local first = source_values
local second = target_values

-- Chat memory refreshes its TTL after each completed turn. Put the list with
-- the longer remaining TTL first so the merged list stays newest-first.
if target_ttl > source_ttl then
  first = target_values
  second = source_values
end

local merged = {}
local seen = {}
local function append_unique(values)
  for _, value in ipairs(values) do
    if #merged >= maximum then
      return
    end
    if not seen[value] then
      seen[value] = true
      table.insert(merged, value)
    end
  end
end

append_unique(first)
append_unique(second)
redis.call('DEL', target)
if #merged > 0 then
  redis.call('RPUSH', target, unpack(merged))
  local ttl = math.max(source_ttl, target_ttl)
  if ttl < 1 then
    ttl = default_ttl
  end
  redis.call('PEXPIRE', target, ttl)
end
redis.call('DEL', source)
return #merged
"""


def get_user_history_id(user: str, site_id: str) -> str:
	"""Derive an environment- and user-specific opaque Redis key."""
	require_user = str(user or "")
	require_site = str(site_id or "")
	if not require_user or require_user == "Guest" or not require_site:
		frappe.throw(_("The AI assistant history identity is invalid."), frappe.AuthenticationError)

	encryption_key = str(frappe.conf.get("encryption_key") or "")
	if len(encryption_key) < 32:
		frappe.throw(_("The AI assistant history key is not configured."), frappe.ValidationError)

	payload = f"{require_site}\0{require_user}".encode("utf-8")
	digest = hmac.new(encryption_key.encode("utf-8"), payload, hashlib.sha256).hexdigest()
	return f"{HISTORY_KEY_PREFIX}{digest}"


def get_visible_history(user: str, site_id: str) -> list[dict[str, str]]:
	"""Return only human/assistant text for the authenticated ERPNext user."""
	history_id = get_user_history_id(user, site_id)
	try:
		values = _redis_client().lrange(history_id, 0, MAX_VISIBLE_HISTORY_MESSAGES - 1)
	except RedisError:
		frappe.log_error(title="AI Assistant visible history read failed")
		frappe.throw(_("The AI assistant history is temporarily unavailable."), frappe.ValidationError)

	newest_first: list[dict[str, str]] = []
	total_chars = 0
	for raw_value in values:
		message = _normalize_memory_message(raw_value, len(newest_first))
		if not message:
			continue
		message_size = len(message["text"])
		if total_chars + message_size > MAX_VISIBLE_HISTORY_CHARS:
			break
		total_chars += message_size
		newest_first.append(message)

	newest_first.reverse()
	return newest_first


def migrate_session_history(session_id: str, history_id: str, ttl_seconds: int) -> int:
	"""Move a pre-upgrade browser-session list into the user history namespace."""
	if not session_id or not history_id or session_id == history_id:
		return 0
	try:
		return int(
			_redis_client().eval(
				_MIGRATE_HISTORY_LUA,
				2,
				str(session_id),
				str(history_id),
				max(1, int(ttl_seconds)) * 1000,
				MAX_MIGRATED_HISTORY_MESSAGES,
			)
		)
	except (RedisError, TypeError, ValueError):
		frappe.log_error(title="AI Assistant session history migration failed")
		return 0


def _normalize_memory_message(raw_value: Any, index: int) -> dict[str, str] | None:
	try:
		payload = json.loads(raw_value)
	except (TypeError, ValueError, json.JSONDecodeError):
		return None
	if not isinstance(payload, dict):
		return None

	message_type = str(payload.get("type") or "").lower()
	if message_type not in {"human", "ai"}:
		return None
	data = payload.get("data")
	if not isinstance(data, dict):
		return None
	text = _message_text(data.get("content"))
	if not text:
		return None
	text = text[:MAX_VISIBLE_MESSAGE_CHARS]
	message_digest = hashlib.sha256(raw_value.encode("utf-8")).hexdigest()[:16]
	return {
		"id": f"history-{index}-{message_digest}",
		"text": text,
		"sender": "user" if message_type == "human" else "bot",
	}


def _message_text(content: Any) -> str:
	if isinstance(content, str):
		return content.strip()
	if not isinstance(content, list):
		return ""
	parts: list[str] = []
	for item in content:
		if isinstance(item, str):
			parts.append(item)
		elif isinstance(item, dict) and isinstance(item.get("text"), str):
			parts.append(item["text"])
	return "\n".join(part.strip() for part in parts if part.strip()).strip()


def _redis_client() -> Redis:
	redis_url = str(frappe.conf.get("ai_assistant_memory_redis_url") or "").strip()
	parsed = urlparse(redis_url)
	if parsed.scheme not in {"redis", "rediss"} or not parsed.hostname:
		frappe.throw(_("The AI assistant memory store is not configured."), frappe.ValidationError)
	return Redis.from_url(
		redis_url,
		decode_responses=True,
		socket_connect_timeout=2,
		socket_timeout=2,
		health_check_interval=30,
	)
