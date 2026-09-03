#!/usr/bin/env bash
set -Eeuo pipefail

# Install the runtime-integrity guard and dependency-ordered ERPNext restart
# helper without changing any Frappe application source or restarting services.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
VOLUME_ROOT="${ERPNEXT_VOLUME_ROOT:-/srv/erpnext}"
BACKUP_ROOT="${VOLUME_ROOT}/private_security/frappe-runtime-parity"
TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
BACKUP_DIR="${BACKUP_ROOT}/${TIMESTAMP}-guard-install"
INTEGRITY_SOURCE="${SCRIPT_DIR}/frappe_runtime_integrity.sh"
RESTART_SOURCE="${SCRIPT_DIR}/erpnext_restart.safe.sh"
INTEGRITY_TARGET="${VOLUME_ROOT}/frappe_runtime_integrity.sh"
RESTART_TARGET="${VOLUME_ROOT}/erpnext_restart.sh"

for source_file in "$INTEGRITY_SOURCE" "$RESTART_SOURCE"; do
	[[ -f "$source_file" ]] || {
		echo "Required source file is missing: $source_file" >&2
		exit 2
	}
	bash -n "$source_file"
done

unchanged=1
cmp -s "$INTEGRITY_SOURCE" "$INTEGRITY_TARGET" || unchanged=0
cmp -s "$RESTART_SOURCE" "$RESTART_TARGET" || unchanged=0
if (( unchanged )); then
	echo "Frappe runtime guard is already installed; no files changed."
	"$INTEGRITY_TARGET" verify
	exit 0
fi

install -d -m 0700 "$BACKUP_DIR"
for target_file in "$INTEGRITY_TARGET" "$RESTART_TARGET"; do
	if [[ -f "$target_file" ]]; then
		cp -a -- "$target_file" "$BACKUP_DIR/$(basename "$target_file").before"
	fi
done

install -m 0755 "$INTEGRITY_SOURCE" "$INTEGRITY_TARGET"
install -m 0755 "$RESTART_SOURCE" "$RESTART_TARGET"

bash -n "$INTEGRITY_TARGET"
bash -n "$RESTART_TARGET"
"$INTEGRITY_TARGET" verify

echo "Installed the Frappe runtime-integrity and safe-restart guards."
echo "Previous files, when present, are in: $BACKUP_DIR"
echo "No Frappe application source, database, Redis data, or container was changed."
