#!/usr/bin/env bash
set -Eeuo pipefail

VOLUME_ROOT="${ERP_VOLUME_ROOT:?Set ERP_VOLUME_ROOT to the persistent deployment root}"
CHECKPOINT_DIR="${REBOOT_CHECKPOINT_DIR:-${VOLUME_ROOT}/private_security/ai-assistant-v2-reboot-check}"
BASELINE_FILE="${CHECKPOINT_DIR}/pre-reboot-baseline.env"
REPORT_FILE="${CHECKPOINT_DIR}/post-reboot-report.txt"
N8N_COMPOSE_FILE="${N8N_COMPOSE_FILE:?Set N8N_COMPOSE_FILE to the deployed Compose file}"
APACHE_VHOST="${AI_APACHE_VHOST:?Set AI_APACHE_VHOST to the ERPNext Apache vhost}"
FRAPPE_PROJECT="${FRAPPE_COMPOSE_PROJECT:-frappe_project}"
WAIT_SECONDS="${REBOOT_VERIFY_WAIT_SECONDS:-180}"
N8N_CONTAINER="${N8N_CONTAINER:-n8n}"
REDIS_CONTAINER="${REDIS_CONTAINER:-n8n-redis}"
VPN_PROXY_CONTAINER="${VPN_PROXY_CONTAINER:-vpn-proxy}"
OPTIONAL_VPN_CONTAINER="${OPTIONAL_VPN_CONTAINER:-vpn-wireguard}"

FRAPPE_CONTAINERS=(
  "${FRAPPE_PROJECT}-db-1"
  "${FRAPPE_PROJECT}-redis-cache-1"
  "${FRAPPE_PROJECT}-redis-queue-1"
  "${FRAPPE_PROJECT}-backend-1"
  "${FRAPPE_PROJECT}-queue-short-1"
  "${FRAPPE_PROJECT}-queue-long-1"
  "${FRAPPE_PROJECT}-websocket-1"
  "${FRAPPE_PROJECT}-scheduler-1"
  "${FRAPPE_PROJECT}-frontend-1"
)
REQUIRED_CONTAINERS=(
  "${REDIS_CONTAINER}"
  "${N8N_CONTAINER}"
  "${VPN_PROXY_CONTAINER}"
  "${FRAPPE_CONTAINERS[@]}"
)
OPTIONAL_CONTAINERS=("${OPTIONAL_VPN_CONTAINER}")
V2_WORKFLOWS=(
  "ERPNext Schema Sync v2"
  "ERPNext Permissioned Query v2"
  "ERPNext AI Chat Assistant v2"
)

failures=0
warnings=0
report_target="/dev/stdout"

usage() {
  cat >&2 <<'EOF'
Usage: reboot_persistence_check.sh {capture|verify|status}

  capture  Save a private pre-reboot baseline and check reboot readiness.
  verify   Compare the recovered host with the saved baseline. Never starts services.
  status   Show whether a baseline exists and the current boot ID only.

Environment overrides:
  REBOOT_CHECKPOINT_DIR, REBOOT_VERIFY_WAIT_SECONDS, ERP_VOLUME_ROOT,
  N8N_COMPOSE_FILE, AI_APACHE_VHOST, FRAPPE_COMPOSE_PROJECT, N8N_CONTAINER,
  REDIS_CONTAINER, VPN_PROXY_CONTAINER, OPTIONAL_VPN_CONTAINER
EOF
  exit 2
}

say() {
  printf '%s\n' "$*" | tee -a "${report_target}"
}

pass() {
  say "PASS: $*"
}

fail() {
  failures=$((failures + 1))
  say "FAIL: $*"
}

warn() {
  warnings=$((warnings + 1))
  say "WARN: $*"
}

boot_id() {
  tr -d '[:space:]' < /proc/sys/kernel/random/boot_id
}

file_hash() {
  local path="$1"
  if [[ -f "${path}" ]]; then
    sha256sum "${path}" | awk '{print $1}'
  else
    printf 'missing'
  fi
}

container_running() {
  [[ "$(docker inspect "$1" --format '{{.State.Running}}' 2>/dev/null || true)" == "true" ]]
}

container_policy() {
  docker inspect "$1" --format '{{.HostConfig.RestartPolicy.Name}}' 2>/dev/null || printf 'missing'
}

container_fingerprint() {
  local name
  for name in "${REQUIRED_CONTAINERS[@]}" "${OPTIONAL_CONTAINERS[@]}"; do
    docker inspect "${name}" \
      --format '{{.Name}}|{{.Config.Image}}|{{.HostConfig.RestartPolicy.Name}}' \
      2>/dev/null || printf '/%s|missing|missing\n' "${name}"
  done | sort | sha256sum | awk '{print $1}'
}

mount_fingerprint() {
  local name mounts
  for name in "${REQUIRED_CONTAINERS[@]}"; do
    mounts="$(docker inspect "${name}" --format '{{json .Mounts}}' 2>/dev/null || true)"
    if [[ -z "${mounts}" ]]; then
      printf '/%s|missing\n' "${name}"
    elif [[ "${mounts}" == "[]" ]]; then
      printf '/%s|none\n' "${name}"
    else
      jq -r --arg name "/${name}" \
        '.[] | [$name, .Type, (.Name // ""), .Source, .Destination] | @tsv' \
        <<< "${mounts}"
    fi
  done | sort | sha256sum | awk '{print $1}'
}

redis_value() {
  docker exec "${REDIS_CONTAINER}" redis-cli "$@" 2>/dev/null | tr -d '\r' || true
}

redis_volume() {
  docker inspect "${REDIS_CONTAINER}" \
    --format '{{range .Mounts}}{{if eq .Destination "/data"}}{{.Name}}{{end}}{{end}}' \
    2>/dev/null || true
}

n8n_data_mount_fingerprint() {
  docker inspect "${N8N_CONTAINER}" \
    --format '{{range .Mounts}}{{if eq .Destination "/home/node/.n8n"}}{{.Type}}|{{.Name}}|{{.Source}}|{{.Destination}}{{end}}{{end}}' \
    2>/dev/null | sha256sum | awk '{print $1}'
}

n8n_health_code() {
  curl --max-time 10 -sS -o /dev/null -w '%{http_code}' \
    http://127.0.0.1:5678/healthz 2>/dev/null || printf '000'
}

frappe_health_code() {
  docker exec "${FRAPPE_PROJECT}-frontend-1" curl --max-time 10 -sS \
    -o /dev/null -w '%{http_code}' -H 'Host: frontend' \
    http://127.0.0.1:8080/api/method/ping 2>/dev/null || printf '000'
}

active_v2_count() {
  local output workflow count=0
  output="$(docker exec "${N8N_CONTAINER}" n8n list:workflow --active=true 2>&1 || true)"
  for workflow in "${V2_WORKFLOWS[@]}"; do
    if grep -Fq "|${workflow}" <<< "${output}"; then
      count=$((count + 1))
    fi
  done
  printf '%s' "${count}"
}

apache_active() {
  systemctl is-active apache2 2>/dev/null || true
}

apache_syntax_ok() {
  apache2ctl configtest 2>&1 | grep -Fq 'Syntax OK'
}

vpn_proxy_ok() {
  docker exec "${VPN_PROXY_CONTAINER}" sh -c 'pidof tinyproxy >/dev/null' >/dev/null 2>&1
}

write_kv() {
  local key="$1" value="$2" target="$3"
  if [[ "${value}" == *$'\n'* ]]; then
    echo "Refusing multiline checkpoint value for ${key}." >&2
    exit 3
  fi
  printf '%s=%s\n' "${key}" "${value}" >> "${target}"
}

read_kv() {
  local key="$1"
  awk -F= -v wanted="${key}" '$1 == wanted {sub(/^[^=]*=/, ""); print; exit}' "${BASELINE_FILE}"
}

wait_for_required_containers() {
  local deadline name all_running
  deadline=$((SECONDS + WAIT_SECONDS))
  while :; do
    all_running=1
    for name in "${REQUIRED_CONTAINERS[@]}"; do
      if ! container_running "${name}"; then
        all_running=0
        break
      fi
    done
    [[ "${all_running}" -eq 1 ]] && return 0
    [[ "${SECONDS}" -ge "${deadline}" ]] && return 1
    sleep 5
  done
}

check_live_health() {
  local expected_redis_count="$1" expected_redis_volume="$2"
  local expected_container_fingerprint="$3" expected_mount_fingerprint="$4"
  local expected_n8n_mount_fingerprint="$5" expected_compose_hash="$6"
  local expected_apache_hash="$7" name value

  for name in "${REQUIRED_CONTAINERS[@]}"; do
    if container_running "${name}"; then
      pass "required container ${name} is running"
    else
      fail "required container ${name} is not running"
    fi
  done

  for name in "${OPTIONAL_CONTAINERS[@]}"; do
    if container_running "${name}"; then
      pass "optional container ${name} is running"
    else
      warn "optional container ${name} is not running"
    fi
  done

  value="$(redis_value PING)"
  [[ "${value}" == "PONG" ]] && pass "Redis responds to PING" || fail "Redis PING returned ${value:-no response}"

  value="$(redis_value DBSIZE)"
  [[ "${value}" == "${expected_redis_count}" ]] && pass "Redis key count remained ${value}" || fail "Redis key count is ${value:-unknown}; expected ${expected_redis_count}"

  value="$(redis_value CONFIG GET appendonly | tail -1)"
  [[ "${value}" == "yes" ]] && pass "Redis AOF remains enabled" || fail "Redis appendonly is ${value:-unknown}"

  value="$(redis_value INFO persistence | awk -F: '$1 == "aof_last_write_status" {gsub(/\r/, "", $2); print $2}')"
  [[ "${value}" == "ok" ]] && pass "Redis AOF write status is healthy" || fail "Redis AOF write status is ${value:-unknown}"

  value="$(redis_volume)"
  [[ -n "${value}" && "${value}" == "${expected_redis_volume}" ]] && pass "Redis named volume identity is unchanged" || fail "Redis volume identity changed or is missing"

  value="$(n8n_health_code)"
  [[ "${value}" == "200" ]] && pass "n8n health is HTTP 200" || fail "n8n health is HTTP ${value}"

  value="$(active_v2_count)"
  [[ "${value}" == "3" ]] && pass "all three v2 workflows are active" || fail "active v2 workflow count is ${value}; expected 3"

  value="$(frappe_health_code)"
  [[ "${value}" == "200" ]] && pass "Frappe ping is HTTP 200" || fail "Frappe ping is HTTP ${value}"

  value="$(apache_active)"
  [[ "${value}" == "active" ]] && pass "Apache is active" || fail "Apache state is ${value:-unknown}"
  apache_syntax_ok && pass "Apache configuration syntax is valid" || fail "Apache configuration test failed"

  value="$(sysctl -n vm.overcommit_memory 2>/dev/null || true)"
  [[ "${value}" == "1" ]] && pass "vm.overcommit_memory remains 1" || fail "vm.overcommit_memory is ${value:-unknown}"

  vpn_proxy_ok && pass "the n8n VPN proxy process is running" || fail "the n8n VPN proxy process is not running"

  value="$(container_fingerprint)"
  [[ "${value}" == "${expected_container_fingerprint}" ]] && pass "container images and restart policies are unchanged" || fail "container image/restart-policy fingerprint changed"

  value="$(mount_fingerprint)"
  [[ "${value}" == "${expected_mount_fingerprint}" ]] && pass "required container mounts are unchanged" || fail "required container mount fingerprint changed"

  value="$(n8n_data_mount_fingerprint)"
  [[ "${value}" == "${expected_n8n_mount_fingerprint}" ]] && pass "n8n persistent data mount is unchanged" || fail "n8n persistent data mount changed"

  value="$(file_hash "${N8N_COMPOSE_FILE}")"
  [[ "${value}" == "${expected_compose_hash}" ]] && pass "n8n Compose checksum is unchanged" || fail "n8n Compose checksum changed"

  value="$(file_hash "${APACHE_VHOST}")"
  [[ "${value}" == "${expected_apache_hash}" ]] && pass "Apache vhost checksum is unchanged" || fail "Apache vhost checksum changed"
}

capture() {
  local temporary name policy unsafe_policy_count=0 value
  local redis_count redis_volume_name container_fp mount_fp n8n_mount_fp

  umask 077
  install -d -m 0700 "${CHECKPOINT_DIR}"
  temporary="$(mktemp "${CHECKPOINT_DIR}/pre-reboot-baseline.XXXXXX")"
  trap "rm -f -- '${temporary}'" EXIT

  report_target="${CHECKPOINT_DIR}/capture-report.txt"
  : > "${report_target}"
  chmod 0600 "${report_target}"
  say "ERPNext AI Assistant v2 pre-reboot capture"
  say "Captured at: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"

  for name in "${REQUIRED_CONTAINERS[@]}"; do
    if ! container_running "${name}"; then
      fail "required container ${name} is not currently running"
    fi
    policy="$(container_policy "${name}")"
    case "${policy}" in
      always|unless-stopped)
        pass "${name} has reboot-capable restart policy ${policy}"
        ;;
      *)
        unsafe_policy_count=$((unsafe_policy_count + 1))
        fail "${name} restart policy ${policy} will not reliably start it after a Docker daemon reboot"
        ;;
    esac
  done

  redis_count="$(redis_value DBSIZE)"
  redis_volume_name="$(redis_volume)"
  container_fp="$(container_fingerprint)"
  mount_fp="$(mount_fingerprint)"
  n8n_mount_fp="$(n8n_data_mount_fingerprint)"

  check_live_health \
    "${redis_count}" "${redis_volume_name}" "${container_fp}" "${mount_fp}" \
    "${n8n_mount_fp}" "$(file_hash "${N8N_COMPOSE_FILE}")" "$(file_hash "${APACHE_VHOST}")"

  write_kv FORMAT_VERSION 1 "${temporary}"
  write_kv CAPTURED_AT_UTC "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "${temporary}"
  write_kv PRE_REBOOT_BOOT_ID "$(boot_id)" "${temporary}"
  write_kv REDIS_DBSIZE "${redis_count}" "${temporary}"
  write_kv REDIS_VOLUME "${redis_volume_name}" "${temporary}"
  write_kv CONTAINER_FINGERPRINT "${container_fp}" "${temporary}"
  write_kv MOUNT_FINGERPRINT "${mount_fp}" "${temporary}"
  write_kv N8N_DATA_MOUNT_FINGERPRINT "${n8n_mount_fp}" "${temporary}"
  write_kv N8N_COMPOSE_SHA256 "$(file_hash "${N8N_COMPOSE_FILE}")" "${temporary}"
  write_kv APACHE_VHOST_SHA256 "$(file_hash "${APACHE_VHOST}")" "${temporary}"
  write_kv RESTART_POLICY_BLOCKERS "${unsafe_policy_count}" "${temporary}"
  write_kv CAPTURE_FAILURES "${failures}" "${temporary}"

  install -m 0600 "${temporary}" "${BASELINE_FILE}"
  say "Private baseline: ${BASELINE_FILE}"
  say "Capture result: failures=${failures}, warnings=${warnings}"
  if [[ "${failures}" -ne 0 ]]; then
    say "REBOOT NOT READY: resolve every failure and run capture again."
    return 1
  fi
  say "REBOOT READY: this script still does not initiate the reboot."
}

verify() {
  local previous_boot current_boot blockers

  [[ -f "${BASELINE_FILE}" ]] || {
    echo "Missing baseline: ${BASELINE_FILE}. Run capture before reboot." >&2
    exit 4
  }

  blockers="$(read_kv RESTART_POLICY_BLOCKERS)"
  if [[ "${blockers}" != "0" ]]; then
    echo "The saved baseline has ${blockers} restart-policy blocker(s). Resolve them and recapture before reboot." >&2
    exit 5
  fi

  previous_boot="$(read_kv PRE_REBOOT_BOOT_ID)"
  current_boot="$(boot_id)"
  if [[ "${previous_boot}" == "${current_boot}" ]]; then
    echo "Boot ID is unchanged; a host reboot has not occurred since capture." >&2
    exit 6
  fi

  umask 077
  install -d -m 0700 "${CHECKPOINT_DIR}"
  : > "${REPORT_FILE}"
  chmod 0600 "${REPORT_FILE}"
  report_target="${REPORT_FILE}"
  say "ERPNext AI Assistant v2 post-reboot verification"
  say "Verified at: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
  pass "host boot ID changed"

  if wait_for_required_containers; then
    pass "all required containers became running within ${WAIT_SECONDS} seconds"
  else
    fail "not all required containers became running within ${WAIT_SECONDS} seconds"
  fi

  check_live_health \
    "$(read_kv REDIS_DBSIZE)" \
    "$(read_kv REDIS_VOLUME)" \
    "$(read_kv CONTAINER_FINGERPRINT)" \
    "$(read_kv MOUNT_FINGERPRINT)" \
    "$(read_kv N8N_DATA_MOUNT_FINGERPRINT)" \
    "$(read_kv N8N_COMPOSE_SHA256)" \
    "$(read_kv APACHE_VHOST_SHA256)"

  say "Post-reboot result: failures=${failures}, warnings=${warnings}"
  say "Private report: ${REPORT_FILE}"
  [[ "${failures}" -eq 0 ]]
}

status() {
  printf 'current_boot_id=%s\n' "$(boot_id)"
  if [[ -f "${BASELINE_FILE}" ]]; then
    printf 'baseline=%s\n' "${BASELINE_FILE}"
    printf 'baseline_boot_id=%s\n' "$(read_kv PRE_REBOOT_BOOT_ID)"
    printf 'restart_policy_blockers=%s\n' "$(read_kv RESTART_POLICY_BLOCKERS)"
    printf 'capture_failures=%s\n' "$(read_kv CAPTURE_FAILURES)"
  else
    printf 'baseline=missing:%s\n' "${BASELINE_FILE}"
  fi
}

case "${1:-}" in
  capture)
    capture
    ;;
  verify)
    verify
    ;;
  status)
    status
    ;;
  *)
    usage
    ;;
esac
