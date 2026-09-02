#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
OVERLAY_ROOT="${SCRIPT_DIR}/hksr_overlay/hksr"
APP_REPOSITORY="${HKSR_APP_REPOSITORY:-/srv/erpnext/apps/hksr}"
APP_PACKAGE="${APP_REPOSITORY}/hksr"
BACKUP_ROOT="${AI_BACKUP_ROOT:-/var/backups/erpnext-ai-assistant}"
MODE="${1:-backend-only}"
RUNTIME_PACKAGE="/home/frappe/frappe-bench/apps/hksr/hksr"
RUNTIME_CONTAINERS="${HKSR_RUNTIME_CONTAINERS:-frappe_docker-queue-short-1 frappe_docker-queue-long-1 frappe_docker-scheduler-1}"
FRONTEND_CONTAINER="${HKSR_FRONTEND_CONTAINER:-frappe_docker-frontend-1}"
FRONTEND_WIDGET_ASSET="/home/frappe/frappe-bench/sites/assets/hksr/js/n8n_chat.js"
WIDGET_ASSET_PATH="/assets/hksr/js/n8n_chat.js"
WIDGET_ASSET_VERSION="${AI_WIDGET_ASSET_VERSION:-ai-v2-YYYYMMDD-1}"
BEGIN_MARKER="# BEGIN HKSR ERPNext AI Assistant v2 hooks"
END_MARKER="# END HKSR ERPNext AI Assistant v2 hooks"

if [[ "${MODE}" != "backend-only" && "${MODE}" != "cutover-widget" ]]; then
  echo "Usage: $0 [backend-only|cutover-widget]" >&2
  exit 2
fi
if [[ ! -f "${APP_PACKAGE}/hooks.py" || ! -d "${APP_REPOSITORY}/.git" ]]; then
  echo "Hksr repository not found at ${APP_REPOSITORY}" >&2
  exit 3
fi

timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
backup_dir="${BACKUP_ROOT}/${timestamp}"
install -d -m 0700 "${backup_dir}"

git -c safe.directory="${APP_REPOSITORY}" -C "${APP_REPOSITORY}" status --short --branch \
  > "${backup_dir}/git-status-before.txt"
git -c safe.directory="${APP_REPOSITORY}" -C "${APP_REPOSITORY}" diff --binary \
  > "${backup_dir}/tracked-changes-before.patch"
tar --exclude='.git' --exclude='__pycache__' --exclude='*.pyc' \
  -C "${APP_REPOSITORY}" -czf "${backup_dir}/hksr-working-tree-before.tar.gz" .
sha256sum "${backup_dir}/hksr-working-tree-before.tar.gz" \
  > "${backup_dir}/hksr-working-tree-before.sha256"

copy_tree() {
  local source_dir="$1" destination_dir="$2" source_file relative_file
  while IFS= read -r -d '' source_file; do
    relative_file="${source_file#${source_dir}/}"
    install -D -m 0644 "${source_file}" "${destination_dir}/${relative_file}"
  done < <(find "${source_dir}" -type f ! -path '*/__pycache__/*' ! -name '*.pyc' -print0)
}

copy_tree "${OVERLAY_ROOT}/ai_assistant" "${APP_PACKAGE}/ai_assistant"
copy_tree "${OVERLAY_ROOT}/hksr/doctype" "${APP_PACKAGE}/hksr/doctype"
if [[ -d "${OVERLAY_ROOT}/hksr/page" ]]; then
  copy_tree "${OVERLAY_ROOT}/hksr/page" "${APP_PACKAGE}/hksr/page"
fi

hooks_candidate="$(mktemp)"
trap 'rm -f -- "${hooks_candidate}"' EXIT
awk -v begin="${BEGIN_MARKER}" -v end="${END_MARKER}" '
  index($0, begin) { skipping = 1; next }
  index($0, end) { skipping = 0; next }
  !skipping { print }
' "${APP_PACKAGE}/hooks.py" > "${hooks_candidate}"

hooks_with_v2="$(mktemp)"
trap 'rm -f -- "${hooks_candidate}" "${hooks_with_v2}"' EXIT
awk -v begin="${BEGIN_MARKER}" -v end="${END_MARKER}" '
  { print }
  !inserted && $0 == "# Scheduled Tasks" {
    getline separator
    print separator
    print ""
    print begin
    print "after_migrate = [\"hksr.ai_assistant.sync.after_migrate\"]"
    print ""
    print "scheduler_events = {"
    print "    \"cron\": {"
    print "        \"30 2 * * *\": [\"hksr.ai_assistant.sync.nightly_schema_sync\"],"
    print "    }"
    print "}"
    print end
    inserted = 1
  }
  END { if (!inserted) exit 42 }
' "${hooks_candidate}" > "${hooks_with_v2}"
install -m 0644 "${hooks_with_v2}" "${APP_PACKAGE}/hooks.py"

if [[ "${MODE}" == "cutover-widget" ]]; then
  hooks_with_widget="$(mktemp)"
  trap 'rm -f -- "${hooks_candidate}" "${hooks_with_v2}" "${hooks_with_widget}"' EXIT
  if ! awk -v path="${WIDGET_ASSET_PATH}" -v version="${WIDGET_ASSET_VERSION}" '
    index($0, path) {
      sub(path "(\\?v=[^\"]*)?", path "?v=" version)
      updated = 1
    }
    { print }
    END { if (!updated) exit 43 }
  ' "${APP_PACKAGE}/hooks.py" > "${hooks_with_widget}"; then
    echo "Could not version the n8n widget URL in Hksr hooks." >&2
    exit 7
  fi
  install -m 0644 "${hooks_with_widget}" "${APP_PACKAGE}/hooks.py"
fi

runtime_stage="$(mktemp -d "${SCRIPT_DIR}/.runtime-stage.XXXXXX")"
trap 'rm -f -- "${hooks_candidate}" "${hooks_with_v2}" "${hooks_with_widget:-}"; rm -rf -- "${runtime_stage}"' EXIT
copy_tree "${OVERLAY_ROOT}/ai_assistant" "${runtime_stage}/ai_assistant"
copy_tree "${OVERLAY_ROOT}/hksr/doctype" "${runtime_stage}/hksr/doctype"
if [[ -d "${OVERLAY_ROOT}/hksr/page" ]]; then
  copy_tree "${OVERLAY_ROOT}/hksr/page" "${runtime_stage}/hksr/page"
fi
install -m 0644 "${APP_PACKAGE}/hooks.py" "${runtime_stage}/hooks.py"

for runtime_container in ${RUNTIME_CONTAINERS}; do
  if ! docker inspect "${runtime_container}" >/dev/null 2>&1; then
    echo "Required Frappe runtime container is missing: ${runtime_container}" >&2
    exit 4
  fi

  runtime_backup="${backup_dir}/runtime-${runtime_container}"
  install -d -m 0700 "${runtime_backup}"
  docker cp "${runtime_container}:${RUNTIME_PACKAGE}/hooks.py" "${runtime_backup}/hooks.py.before"
  for relative_target in \
    "ai_assistant" \
    "hksr/doctype/ai_assistant_settings" \
    "hksr/doctype/ai_assistant_allowed_doctype" \
    "hksr/page/ai_assistant_v2_uat"; do
    if docker exec "${runtime_container}" test -e "${RUNTIME_PACKAGE}/${relative_target}"; then
      install -d -m 0700 "${runtime_backup}/$(dirname -- "${relative_target}")"
      docker cp \
        "${runtime_container}:${RUNTIME_PACKAGE}/${relative_target}" \
        "${runtime_backup}/${relative_target}.before"
    fi
  done

  docker cp -a "${runtime_stage}/." "${runtime_container}:${RUNTIME_PACKAGE}/"
  docker exec -u root "${runtime_container}" chown -R frappe:frappe \
    "${RUNTIME_PACKAGE}/ai_assistant" \
    "${RUNTIME_PACKAGE}/hksr/doctype/ai_assistant_settings" \
    "${RUNTIME_PACKAGE}/hksr/doctype/ai_assistant_allowed_doctype" \
    "${RUNTIME_PACKAGE}/hksr/page/ai_assistant_v2_uat" \
    "${RUNTIME_PACKAGE}/hooks.py"
  docker exec -u frappe "${runtime_container}" python -m compileall -q \
    "${RUNTIME_PACKAGE}/ai_assistant" \
    "${RUNTIME_PACKAGE}/hksr/doctype"
  echo "Synchronized AI Assistant v2 runtime code to ${runtime_container}."
done

if [[ "${MODE}" == "cutover-widget" ]]; then
  install -m 0644 "${OVERLAY_ROOT}/public/js/n8n_chat.js" "${APP_PACKAGE}/public/js/n8n_chat.js"
  if ! docker inspect "${FRONTEND_CONTAINER}" >/dev/null 2>&1; then
    echo "Required Frappe frontend container is missing: ${FRONTEND_CONTAINER}" >&2
    exit 5
  fi

  if docker exec "${FRONTEND_CONTAINER}" test -f "${FRONTEND_WIDGET_ASSET}"; then
    docker cp \
      "${FRONTEND_CONTAINER}:${FRONTEND_WIDGET_ASSET}" \
      "${backup_dir}/frontend-n8n_chat.js.before"
  fi

  frontend_stage="/tmp/hksr-n8n-chat-v2-${timestamp}.js"
  docker cp "${OVERLAY_ROOT}/public/js/n8n_chat.js" \
    "${FRONTEND_CONTAINER}:${frontend_stage}"
  docker exec -u root "${FRONTEND_CONTAINER}" install -D -m 0644 \
    -o frappe -g frappe "${frontend_stage}" "${FRONTEND_WIDGET_ASSET}"
  docker exec -u root "${FRONTEND_CONTAINER}" rm -f "${frontend_stage}"

  expected_widget_hash="$(sha256sum "${OVERLAY_ROOT}/public/js/n8n_chat.js" | awk '{print $1}')"
  repository_widget_hash="$(sha256sum "${APP_PACKAGE}/public/js/n8n_chat.js" | awk '{print $1}')"
  frontend_widget_hash="$(docker exec "${FRONTEND_CONTAINER}" sha256sum "${FRONTEND_WIDGET_ASSET}" | awk '{print $1}')"
  if [[ "${repository_widget_hash}" != "${expected_widget_hash}" || \
        "${frontend_widget_hash}" != "${expected_widget_hash}" ]]; then
    echo "The v2 widget checksum differs between tracked source, app source, or frontend asset." >&2
    exit 6
  fi

  echo "Installed and checksum-verified the v2 bootstrap widget in the app source and frontend asset filesystem."
  echo "Apply or verify the exact Apache route atomically in the same cutover window."
else
  echo "Backend-only shadow installed; the existing widget loader was not changed."
fi

python3 -m compileall -q "${APP_PACKAGE}/ai_assistant" "${APP_PACKAGE}/hksr/doctype"
echo "Pre-change backup: ${backup_dir}"
if [[ "${MODE}" == "cutover-widget" ]]; then
  echo "Next: clear the Frappe site cache and verify the public widget asset and exact Apache route; no container recreation is required."
else
  echo "Next: run bench --site frontend migrate and use the persistent ERPNext restart script so every synchronized worker reloads hooks."
fi
