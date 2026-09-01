#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_PATH="${1:-${SCRIPT_DIR}/workflows.rendered.json}"

: "${AI_CHAT_WEBHOOK_ID:?Set a unique AI_CHAT_WEBHOOK_ID for this environment}"
: "${AI_SCHEMA_SYNC_WEBHOOK_ID:?Set a unique AI_SCHEMA_SYNC_WEBHOOK_ID for this environment}"

safe_id='^[A-Za-z0-9][A-Za-z0-9_-]{15,127}$'
if [[ ! "${AI_CHAT_WEBHOOK_ID}" =~ ${safe_id} ]]; then
  echo "AI_CHAT_WEBHOOK_ID has an invalid format" >&2
  exit 2
fi
if [[ ! "${AI_SCHEMA_SYNC_WEBHOOK_ID}" =~ ${safe_id} ]]; then
  echo "AI_SCHEMA_SYNC_WEBHOOK_ID has an invalid format" >&2
  exit 2
fi

tmp_path="$(mktemp)"
trap 'rm -f -- "${tmp_path}"' EXIT

jq -s \
  --arg chat_webhook_id "${AI_CHAT_WEBHOOK_ID}" \
  --arg sync_webhook_id "${AI_SCHEMA_SYNC_WEBHOOK_ID}" \
  'add | walk(
    if type == "string" then
      gsub("__AI_CHAT_WEBHOOK_ID__"; $chat_webhook_id)
      | gsub("__AI_SCHEMA_SYNC_WEBHOOK_ID__"; $sync_webhook_id)
    else . end
  )' \
  "${SCRIPT_DIR}/workflows/erpnext-schema-sync-v2.json" \
  "${SCRIPT_DIR}/workflows/erpnext-permissioned-query-v2.json" \
  "${SCRIPT_DIR}/workflows/erpnext-ai-chat-assistant-v2.json" \
  > "${tmp_path}"

if rg -q '__AI_[A-Z_]+__' "${tmp_path}"; then
  echo "An unresolved workflow placeholder remains" >&2
  exit 3
fi

jq empty "${tmp_path}"
install -m 0600 "${tmp_path}" "${OUTPUT_PATH}"
sha256sum "${OUTPUT_PATH}"
echo "Rendered inactive shadow workflows: ${OUTPUT_PATH}"
