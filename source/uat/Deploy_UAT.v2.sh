#!/usr/bin/env bash
# Stage production configuration and test data for UAT. This script never starts
# UAT containers and intentionally does not copy VPN credentials, n8n credentials,
# encryption keys, or n8n's SQLite database.
set -Eeuo pipefail

UAT_SERVER="${UAT_SERVER:-10.90.101.7}"
ROOT_FOLDER="${ROOT_FOLDER:-/srv/erpnext}"
PASSWORD_FILE="${ERPNEXT_SSH_PASSWORD_FILE:-/run/secrets/erpnext_ssh_password}"
REMOTE_FOLDER="${UAT_STAGE_DIR:-$ROOT_FOLDER/hksr_updates}"
REMOTE="${ERPNEXT_BACKEND_SSH_REMOTE:-root@$UAT_SERVER:$REMOTE_FOLDER}"

REMOTE_BACKEND="$REMOTE_FOLDER/backend_program"
REMOTE_HKSR="$REMOTE_BACKEND/hksr"
REMOTE_CONFIGURE="$REMOTE_FOLDER/configure"
REMOTE_DOCTYPE="$REMOTE_FOLDER/doctype"
REMOTE_SUPERSET="$REMOTE_FOLDER/superset"
REMOTE_N8N="$REMOTE_CONFIGURE/n8n"
REMOTE_VPN="$REMOTE_CONFIGURE/vpn-proxy"
N8N_SOURCE="$ROOT_FOLDER/n8n"
MOUNTED_BY_SCRIPT=0
##EXCLUDE_FILE="$ROOT_FOLDER/hksr_uat_exclude_dt.txt"    ## update on production ##
##EXCLUDE_DT="`grep -v '^##' $EXCLUDE_FILE | grep -v '^$' | paste -sd, -`"
$ROOT_FOLDER/hksr_uat_include_dt.sh

INCLUDE_FILES="`cat $ROOT_FOLDER/included_doctypes.txt`"

cleanup() {
	if [[ "$MOUNTED_BY_SCRIPT" == "1" ]] && mountpoint -q "$REMOTE_FOLDER"; then
		fusermount3 -u "$REMOTE_FOLDER" 2>/dev/null || umount "$REMOTE_FOLDER"
	fi
}
trap cleanup EXIT

require_command() {
	command -v "$1" >/dev/null || {
		echo "Required command not found: $1" >&2
		exit 1
	}
}

copy_latest_site_backup() {
	local backup_dir="/home/frappe/frappe-bench/sites/frontend/private/backups"
	local database_backup
	local config_backup

	echo "Creating an ERPNext site backup (only include $INCLUDE_FILES)..."
	docker exec frappe_docker-backend-1 bench --site frontend backup --with-files --include "$INCLUDE_FILES"

	database_backup="$(docker exec frappe_docker-backend-1 sh -lc \
		"find '$backup_dir' -maxdepth 1 -type f -name '*-frontend-database.sql.gz' -printf '%T@ %p\\n' | sort -nr | head -n 1 | cut -d' ' -f2-")"
	config_backup="$(docker exec frappe_docker-backend-1 sh -lc \
		"find '$backup_dir' -maxdepth 1 -type f -name '*-frontend-site_config_backup.json' -printf '%T@ %p\\n' | sort -nr | head -n 1 | cut -d' ' -f2-")"

	[[ -n "$database_backup" && -n "$config_backup" ]] || {
		echo "Could not locate the newly-created ERPNext backup files." >&2
		exit 1
	}

	docker cp "frappe_docker-backend-1:$database_backup" "$REMOTE_DOCTYPE/"
	docker cp "frappe_docker-backend-1:$config_backup" "$REMOTE_DOCTYPE/"
}

stage_n8n() {
	echo "Staging n8n configuration and workflow definitions..."
	install -d "$REMOTE_N8N" "$REMOTE_N8N/ai-assistant-v2" "$REMOTE_VPN"

	rsync -a \
		"$N8N_SOURCE/docker-compose.yml" \
		"$N8N_SOURCE/webhook-helpers.js" \
		"$REMOTE_N8N/"
	rsync -a \
		"$N8N_SOURCE/uat/n8n.uat.env.example" \
		"$N8N_SOURCE/uat/UAT_DEPLOYMENT.md" \
		"$REMOTE_N8N/"
	rsync -a --exclude='workflows.rendered.json' --exclude='__pycache__' --exclude='*.pyc' \
		"$N8N_SOURCE/ai-assistant-v2/" \
		"$REMOTE_N8N/ai-assistant-v2/"
	rsync -a \
		"$N8N_SOURCE/uat/vpn-proxy.compose.yml" \
		"$N8N_SOURCE/uat/vpn-proxy.env.example" \
		"$REMOTE_VPN/"

	# Export workflow definitions only. The UAT operator must recreate credentials
	# against UAT services after import.
	docker exec n8n n8n export:workflow --all --output=/tmp/n8n-uat-workflows.json
	docker cp n8n:/tmp/n8n-uat-workflows.json "$REMOTE_N8N/workflows.json"
	docker exec n8n rm -f /tmp/n8n-uat-workflows.json >/dev/null
	# Production v2 workflow IDs are deliberately excluded. UAT renders the
	# staged templates with fresh UAT-only IDs before import.
	jq '[.[] | select((.name | endswith("v2")) | not)]' \
		"$REMOTE_N8N/workflows.json" > "$REMOTE_N8N/workflows.legacy.json"
	mv "$REMOTE_N8N/workflows.legacy.json" "$REMOTE_N8N/workflows.json"
	docker exec n8n n8n --version > "$REMOTE_N8N/n8n-version.txt"
}

stage_application_files() {
	local -a db_connector_files=()
	local -a root_files=()

	echo "Staging db_connector, the n8n Desk widget, and operational scripts..."
	shopt -s nullglob
	db_connector_files=("$ROOT_FOLDER/backend/apps/db_connector/db_connector/"*.py
		"$ROOT_FOLDER/backend/apps/db_connector/db_connector/"*.sh)
	root_files=("$ROOT_FOLDER/"*.sh "$ROOT_FOLDER/"*.txt)
	shopt -u nullglob

	((${#db_connector_files[@]})) && rsync -a "${db_connector_files[@]}" "$REMOTE_BACKEND/"
	((${#root_files[@]})) && rsync -a "${root_files[@]}" "$REMOTE_FOLDER/"
	install -d "$REMOTE_HKSR/hksr/public/js" "$REMOTE_HKSR/hksr/public/css"
	rsync -a \
		"$ROOT_FOLDER/backend/apps/hksr/hksr/hooks.py" \
		"$REMOTE_HKSR/hksr/"
	rsync -a \
		"$ROOT_FOLDER/backend/apps/hksr/hksr/public/js/n8n_chat.js" \
		"$ROOT_FOLDER/backend/apps/hksr/hksr/public/js/n8n_chat_umd.js" \
		"$REMOTE_HKSR/hksr/public/js/"
	rsync -a \
		"$ROOT_FOLDER/backend/apps/hksr/hksr/public/css/n8n_chat_style.css" \
		"$REMOTE_HKSR/hksr/public/css/"
}

stage_superset() {
	local dashboard_archive="/home/frappe-user/superset/dashboards.zip"

	if [[ ! -x /home/frappe-user/superset/backup.sh ]]; then
		echo "Skipping Superset: /home/frappe-user/superset/backup.sh is unavailable."
		return
	fi

	echo "Staging Superset dashboard and configuration files..."
	su -s /bin/sh frappe-user -c /home/frappe-user/superset/backup.sh
	[[ -f "$dashboard_archive" ]] && cp "$dashboard_archive" "$REMOTE_SUPERSET/"
	[[ -f /home/frappe-user/superset/superset_config.py ]] && \
		cp /home/frappe-user/superset/superset_config.py "$REMOTE_SUPERSET/"
}

for required_command in docker jq sshfs sshpass rsync; do
	require_command "$required_command"
done
[[ -r "$PASSWORD_FILE" ]] || {
	echo "SSH password file is not readable: $PASSWORD_FILE" >&2
	exit 1
}
[[ -f "$N8N_SOURCE/docker-compose.yml" ]] || {
	echo "n8n source configuration is missing: $N8N_SOURCE/docker-compose.yml" >&2
	exit 1
}
[[ -d "$N8N_SOURCE/ai-assistant-v2" ]] || {
	echo "AI Assistant v2 source is missing: $N8N_SOURCE/ai-assistant-v2" >&2
	exit 1
}

read -r -p "Stage ERPNext, n8n workflows, and secret-free VPN templates to UAT? [y/N] " answer
[[ "$answer" =~ ^[Yy]$ ]] || exit 0

mkdir -p "$REMOTE_FOLDER"
if ! mountpoint -q "$REMOTE_FOLDER"; then
	echo "Mounting UAT staging directory at $REMOTE_FOLDER..."
	sshfs "$REMOTE" "$REMOTE_FOLDER" \
		-o "ssh_command=sshpass -f $PASSWORD_FILE ssh -o StrictHostKeyChecking=accept-new -o ServerAliveInterval=15" \
		-o allow_other,reconnect,ServerAliveCountMax=3
	MOUNTED_BY_SCRIPT=1
fi
mountpoint -q "$REMOTE_FOLDER" || {
	echo "UAT staging directory is not mounted: $REMOTE_FOLDER" >&2
	exit 1
}

install -d "$REMOTE_BACKEND" "$REMOTE_CONFIGURE" "$REMOTE_DOCTYPE" "$REMOTE_SUPERSET"
copy_latest_site_backup
stage_application_files
stage_n8n
stage_superset

echo "UAT staging complete: $REMOTE_FOLDER"
echo "On UAT, follow configure/n8n/UAT_DEPLOYMENT.md before starting n8n or the VPN proxy."
