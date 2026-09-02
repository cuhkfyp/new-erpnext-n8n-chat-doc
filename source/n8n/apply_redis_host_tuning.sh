#!/usr/bin/env bash
set -Eeuo pipefail

SYSCTL_CONF="${REDIS_SYSCTL_CONF:-/etc/sysctl.d/90-n8n-redis.conf}"
SETTING="vm.overcommit_memory"
EXPECTED_VALUE="1"

usage() {
  echo "Usage: $0 {status|apply}" >&2
  exit 2
}

show_status() {
  local live_value
  live_value="$(sysctl -n "${SETTING}")"
  printf 'live_%s=%s\n' "${SETTING//./_}" "${live_value}"

  if [[ -f "${SYSCTL_CONF}" ]]; then
    printf 'persistent_config=%s\n' "${SYSCTL_CONF}"
    sed -n '1,20p' "${SYSCTL_CONF}"
  else
    printf 'persistent_config=missing:%s\n' "${SYSCTL_CONF}"
  fi

  [[ "${live_value}" == "${EXPECTED_VALUE}" ]] &&
    [[ -f "${SYSCTL_CONF}" ]] &&
    grep -Eq '^vm\.overcommit_memory[[:space:]]*=[[:space:]]*1[[:space:]]*$' "${SYSCTL_CONF}"
}

apply_setting() {
  local temporary

  if [[ "${EUID}" -ne 0 ]]; then
    echo "Run as root to apply the Redis host tuning." >&2
    exit 3
  fi

  temporary="$(mktemp)"
  trap "rm -f -- '${temporary}'" EXIT
  printf '%s = %s\n' "${SETTING}" "${EXPECTED_VALUE}" > "${temporary}"
  install -m 0644 "${temporary}" "${SYSCTL_CONF}"
  sysctl -w "${SETTING}=${EXPECTED_VALUE}"
  show_status
}

case "${1:-}" in
  status)
    show_status
    ;;
  apply)
    apply_setting
    ;;
  *)
    usage
    ;;
esac
