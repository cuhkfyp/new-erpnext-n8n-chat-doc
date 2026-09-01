#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
VOLUME_ROOT="${ERP_VOLUME_ROOT:-/srv/erpnext}"
N8N_ROOT="${VOLUME_ROOT}/n8n"
DESTINATION="${N8N_ROOT}/ai-assistant-v2"
BACKUP_ROOT="${AI_CONFIG_BACKUP_ROOT:-/var/backups/erpnext-ai-assistant-config}"
TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
BACKUP_DIR="${BACKUP_ROOT}/${TIMESTAMP}"

require_file() {
  [[ -f "$1" ]] || {
    echo "Required file is missing: $1" >&2
    exit 2
  }
}

append_section() {
  local target="$1" section_name="$2" appendix="$3" marker_style="${4:-html}" temporary
  local begin_html="<!-- BEGIN ${section_name} -->"
  local end_html="<!-- END ${section_name} -->"
  local begin_hash="# BEGIN ${section_name}"
  local end_hash="# END ${section_name}"
  local begin_marker="${begin_html}"
  local end_marker="${end_html}"

  if [[ "${marker_style}" == "hash" ]]; then
    begin_marker="${begin_hash}"
    end_marker="${end_hash}"
  fi

  require_file "${target}"
  require_file "${appendix}"
  temporary="$(mktemp)"
  awk \
    -v begin_html="${begin_html}" -v end_html="${end_html}" \
    -v begin_hash="${begin_hash}" -v end_hash="${end_hash}" '
    index($0, begin_html) || index($0, begin_hash) { skipping = 1; next }
    index($0, end_html) || index($0, end_hash) { skipping = 0; next }
    !skipping { print }
  ' "${target}" > "${temporary}"
  {
    printf '\n%s\n\n' "${begin_marker}"
    sed -n '1,$p' "${appendix}"
    printf '\n%s\n' "${end_marker}"
  } >> "${temporary}"
  install -m "$(stat -c '%a' "${target}")" "${temporary}" "${target}"
  rm -f -- "${temporary}"
}

for required in \
  "${N8N_ROOT}/docker-compose.yml" \
  "${N8N_ROOT}/N8N_SETUP_AND_OPERATIONS.md" \
  "${N8N_ROOT}/uat/UAT_DEPLOYMENT.md" \
  "${N8N_ROOT}/uat/n8n.uat.env.example" \
  "${VOLUME_ROOT}/DEPLOY_UAT.md" \
  "${VOLUME_ROOT}/Deploy_UAT.sh"; do
  require_file "${required}"
done

install -d -m 0700 "${BACKUP_DIR}"
cp -a "${N8N_ROOT}/docker-compose.yml" "${BACKUP_DIR}/docker-compose.yml.before"
cp -a "${N8N_ROOT}/N8N_SETUP_AND_OPERATIONS.md" "${BACKUP_DIR}/N8N_SETUP_AND_OPERATIONS.md.before"
cp -a "${N8N_ROOT}/uat/UAT_DEPLOYMENT.md" "${BACKUP_DIR}/UAT_DEPLOYMENT.md.before"
cp -a "${N8N_ROOT}/uat/n8n.uat.env.example" "${BACKUP_DIR}/n8n.uat.env.example.before"
cp -a "${VOLUME_ROOT}/DEPLOY_UAT.md" "${BACKUP_DIR}/DEPLOY_UAT.md.before"
cp -a "${VOLUME_ROOT}/Deploy_UAT.sh" "${BACKUP_DIR}/Deploy_UAT.sh.before"

install -d "${DESTINATION}"
rsync -a --exclude='workflows.rendered.json' --exclude='__pycache__' --exclude='*.pyc' \
  "${SCRIPT_DIR}/" "${DESTINATION}/"

install -m 0644 "${SCRIPT_DIR}/n8n/docker-compose.v2.yml" "${N8N_ROOT}/docker-compose.yml"
install -m 0755 "${SCRIPT_DIR}/uat/Deploy_UAT.v2.sh" "${VOLUME_ROOT}/Deploy_UAT.sh"

append_section \
  "${N8N_ROOT}/N8N_SETUP_AND_OPERATIONS.md" \
  "ERPNext AI Assistant v2 operations" \
  "${SCRIPT_DIR}/n8n/N8N_GUIDE_V2_APPENDIX.md"
append_section \
  "${N8N_ROOT}/uat/UAT_DEPLOYMENT.md" \
  "ERPNext AI Assistant v2 UAT" \
  "${SCRIPT_DIR}/uat/UAT_V2_APPENDIX.md"
append_section \
  "${VOLUME_ROOT}/DEPLOY_UAT.md" \
  "ERPNext AI Assistant v2 UAT" \
  "${SCRIPT_DIR}/uat/UAT_V2_APPENDIX.md"
append_section \
  "${N8N_ROOT}/uat/n8n.uat.env.example" \
  "ERPNext AI Assistant v2 UAT environment" \
  "${SCRIPT_DIR}/uat/n8n.uat.env.v2.example" \
  hash

echo "Installed persistent AI Assistant v2 source and documentation."
echo "Configuration backup: ${BACKUP_DIR}"
echo "The running n8n container and Apache routing were not restarted or changed."
