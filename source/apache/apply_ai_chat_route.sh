#!/usr/bin/env bash
set -Eeuo pipefail

ACTION="${1:-verify}"
VHOST_PATH="${AI_APACHE_VHOST:-/etc/apache2/sites-available/erp.example.com-ssl.conf}"
N8N_TARGET="${AI_N8N_TARGET:-http://127.0.0.1:5678}"
PUBLIC_ORIGIN="${AI_PUBLIC_ORIGIN:-https://erp.example.com}"
PUBLIC_HOST="${AI_PUBLIC_HOST:-erp.example.com}"
PUBLIC_PORT="${AI_PUBLIC_PORT:-443}"
PUBLIC_RESOLVE_ADDRESS="${AI_PUBLIC_RESOLVE_ADDRESS:-127.0.0.1}"
STATE_DIR="${AI_APACHE_STATE_DIR:-/var/lib/erpnext-ai-assistant}"
BEGIN_MARKER="# BEGIN ERPNext AI Assistant v2 route"
END_MARKER="# END ERPNext AI Assistant v2 route"

usage() {
  echo "Usage:" >&2
  echo "  AI_CHAT_WEBHOOK_ID=<environment-id> $0 apply" >&2
  echo "  AI_CHAT_WEBHOOK_ID=<environment-id> $0 verify" >&2
  echo "  $0 rollback /absolute/path/to/vhost.backup" >&2
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "This action must run as root." >&2
    exit 1
  fi
}

validate_webhook_id() {
  : "${AI_CHAT_WEBHOOK_ID:?Set AI_CHAT_WEBHOOK_ID for this environment}"
  if [[ ! "${AI_CHAT_WEBHOOK_ID}" =~ ^[A-Za-z0-9][A-Za-z0-9_-]{15,127}$ ]]; then
    echo "AI_CHAT_WEBHOOK_ID has an invalid format." >&2
    exit 2
  fi
  PUBLIC_PATH="/n8n-webhook/${AI_CHAT_WEBHOOK_ID}/chat"
  UPSTREAM_PATH="/webhook/${AI_CHAT_WEBHOOK_ID}/chat"
}

route_block() {
  printf '%s\n' \
    "        ${BEGIN_MARKER}" \
    "        ProxyPass \"${PUBLIC_PATH}\" \"${N8N_TARGET}${UPSTREAM_PATH}\" nocanon retry=0" \
    "        ProxyPassReverse \"${PUBLIC_PATH}\" \"${N8N_TARGET}${UPSTREAM_PATH}\"" \
    "        ${END_MARKER}"
}

config_test() {
  apache2ctl configtest
}

reload_apache() {
  apache2ctl graceful
}

verify_route() (
  validate_webhook_id
  if [[ ! -r "${VHOST_PATH}" ]]; then
    echo "Cannot read vhost: ${VHOST_PATH}" >&2
    return 3
  fi

  local begin_line catchall_line
  begin_line="$(awk -v marker="${BEGIN_MARKER}" '$0 ~ marker { print NR; exit }' "${VHOST_PATH}")"
  catchall_line="$(awk '$1 == "ProxyPass" && $2 == "/" { print NR; exit }' "${VHOST_PATH}")"
  if [[ -z "${begin_line}" || -z "${catchall_line}" || "${begin_line}" -ge "${catchall_line}" ]]; then
    echo "The exact AI route is missing or is not before the catch-all ProxyPass." >&2
    return 4
  fi
  if ! rg -Fq "${N8N_TARGET}${UPSTREAM_PATH}" "${VHOST_PATH}"; then
    echo "The AI route does not point to the expected n8n webhook." >&2
    return 4
  fi

  if ! config_test; then
    echo "Apache configuration validation failed during route verification." >&2
    return 7
  fi

  local temp_dir direct_status proxy_status direct_type proxy_type
  temp_dir="$(mktemp -d)"
  trap 'rm -rf -- "${temp_dir}"' EXIT
  if ! direct_status="$(curl --silent --show-error --max-time 10 \
    --noproxy '*' \
    --output "${temp_dir}/direct.body" --dump-header "${temp_dir}/direct.headers" \
    --write-out '%{http_code}' --request POST \
    --header 'Content-Type: application/json' \
    --data '{"action":"loadPreviousSession","sessionId":"route-verification"}' \
    "${N8N_TARGET}${UPSTREAM_PATH}")"; then
    echo "Direct n8n route verification request failed." >&2
    return 5
  fi
  if ! proxy_status="$(curl --silent --show-error --insecure --max-time 10 \
    --noproxy '*' \
    --resolve "${PUBLIC_HOST}:${PUBLIC_PORT}:${PUBLIC_RESOLVE_ADDRESS}" \
    --output "${temp_dir}/proxy.body" --dump-header "${temp_dir}/proxy.headers" \
    --write-out '%{http_code}' --request POST \
    --header 'Content-Type: application/json' \
    --data '{"action":"loadPreviousSession","sessionId":"route-verification"}' \
    "${PUBLIC_ORIGIN}${PUBLIC_PATH}")"; then
    echo "Public Apache route verification request failed." >&2
    return 5
  fi
  direct_type="$(awk 'tolower($1) == "content-type:" { print tolower($2); exit }' "${temp_dir}/direct.headers" | tr -d '\r')"
  proxy_type="$(awk 'tolower($1) == "content-type:" { print tolower($2); exit }' "${temp_dir}/proxy.headers" | tr -d '\r')"

  if rg -qi '<title>Server Error</title>|frappe\.app|Traceback' "${temp_dir}/proxy.body"; then
    echo "Proxy verification reached Frappe instead of n8n." >&2
    return 5
  fi
  if [[ "${proxy_status}" != "${direct_status}" || "${proxy_type}" != "${direct_type}" ]]; then
    echo "Proxy and direct n8n responses differ (direct ${direct_status}/${direct_type}, proxy ${proxy_status}/${proxy_type})." >&2
    return 5
  fi
  echo "Verified ${PUBLIC_PATH} routes to n8n (HTTP ${proxy_status}, content-type ${proxy_type:-unknown})."
)

apply_route() {
  require_root
  validate_webhook_id
  for command in apache2ctl awk curl install mktemp rg; do
    command -v "${command}" >/dev/null
  done
  if [[ ! -f "${VHOST_PATH}" ]]; then
    echo "Vhost does not exist: ${VHOST_PATH}" >&2
    exit 3
  fi

  install -d -m 0700 "${STATE_DIR}"
  local timestamp backup_path stripped_path candidate_path
  timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
  backup_path="${STATE_DIR}/$(basename "${VHOST_PATH}").before-ai-v2.${timestamp}"
  install -m 0600 "${VHOST_PATH}" "${backup_path}"
  stripped_path="$(mktemp)"
  candidate_path="$(mktemp)"
  trap 'rm -f -- "${stripped_path}" "${candidate_path}"' RETURN

  awk -v begin="${BEGIN_MARKER}" -v end="${END_MARKER}" '
    index($0, begin) { skipping = 1; next }
    index($0, end) { skipping = 0; next }
    !skipping { print }
  ' "${VHOST_PATH}" > "${stripped_path}"

  local block
  block="$(route_block)"
  if ! awk -v block="${block}" '
    !inserted && $1 == "ProxyPass" && $2 == "/" { print block; inserted = 1 }
    { print }
    END { if (!inserted) exit 42 }
  ' "${stripped_path}" > "${candidate_path}"; then
    echo "Could not find the catch-all ProxyPass in ${VHOST_PATH}." >&2
    exit 6
  fi

  install -m "$(stat -c '%a' "${VHOST_PATH}")" -o "$(stat -c '%u' "${VHOST_PATH}")" -g "$(stat -c '%g' "${VHOST_PATH}")" \
    "${candidate_path}" "${VHOST_PATH}"
  if ! config_test; then
    install -m 0644 "${backup_path}" "${VHOST_PATH}"
    config_test || true
    echo "Apache config test failed; restored ${backup_path}." >&2
    exit 7
  fi
  reload_apache
  echo "Applied exact webhook route. Rollback backup: ${backup_path}"
  if verify_route; then
    :
  else
    local verify_status=$?
    install -m "$(stat -c '%a' "${VHOST_PATH}")" -o "$(stat -c '%u' "${VHOST_PATH}")" -g "$(stat -c '%g' "${VHOST_PATH}")" \
      "${backup_path}" "${VHOST_PATH}"
    config_test
    reload_apache
    echo "Route verification failed; restored ${backup_path}." >&2
    return "${verify_status}"
  fi
}

rollback_route() {
  require_root
  local backup_path="${2:-}"
  if [[ -z "${backup_path}" || "${backup_path}" != /* || ! -f "${backup_path}" ]]; then
    usage
    exit 2
  fi
  local safety_backup
  install -d -m 0700 "${STATE_DIR}"
  safety_backup="${STATE_DIR}/$(basename "${VHOST_PATH}").before-rollback.$(date -u +%Y%m%dT%H%M%SZ)"
  install -m 0600 "${VHOST_PATH}" "${safety_backup}"
  install -m "$(stat -c '%a' "${VHOST_PATH}")" -o "$(stat -c '%u' "${VHOST_PATH}")" -g "$(stat -c '%g' "${VHOST_PATH}")" \
    "${backup_path}" "${VHOST_PATH}"
  if ! config_test; then
    install -m 0644 "${safety_backup}" "${VHOST_PATH}"
    echo "Rollback candidate failed configtest; restored ${safety_backup}." >&2
    exit 7
  fi
  reload_apache
  echo "Rolled back Apache vhost from ${backup_path}. Safety backup: ${safety_backup}"
}

case "${ACTION}" in
  apply) apply_route ;;
  verify) verify_route ;;
  rollback) rollback_route "$@" ;;
  *) usage; exit 2 ;;
esac
