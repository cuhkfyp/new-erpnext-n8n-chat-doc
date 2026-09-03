#!/usr/bin/env bash
set -Eeuo pipefail

# Keep every Python Frappe runtime on the same hook-bearing application code.
# The live backend is the canonical source because it is the code serving Desk.

MODE="${1:-verify}"
SITE="${FRAPPE_SITE:-frontend}"
CANONICAL_CONTAINER="${FRAPPE_CANONICAL_CONTAINER:-frappe_docker-backend-1}"
APP_ROOT="/home/frappe/frappe-bench/apps"
BENCH_ROOT="/home/frappe/frappe-bench"
TARGETS=(
	frappe_docker-scheduler-1
	frappe_docker-queue-short-1
	frappe_docker-queue-long-1
)
OBSOLETE_HOOKS=(
	sheets.boot.extend_bootinfo
	drive.api.product.after_request
)

usage() {
	cat <<'USAGE'
Usage: frappe_runtime_integrity.sh [audit|verify|sync|warm-cache]

  audit       Print hook checksums and report drift without changing anything.
  verify      Require hook parity and reject obsolete cached hook paths.
  sync        Preserve drifted packages in each container, copy the live
              backend package atomically, rebuild the hook cache, and restart
              only scheduler/queue workers.
  warm-cache  Clear and rebuild the Frappe hook cache from the backend. Worker
              and scheduler containers must already be stopped.
USAGE
}

container_running() {
	[[ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null)" == "true" ]]
}

require_containers() {
	local container
	for container in "$CANONICAL_CONTAINER" "${TARGETS[@]}"; do
		docker inspect "$container" >/dev/null
	done
	container_running "$CANONICAL_CONTAINER" || {
		echo "Canonical backend is not running: $CANONICAL_CONTAINER" >&2
		exit 2
	}
}

installed_apps() {
	docker exec "$CANONICAL_CONTAINER" sh -lc \
		'tr "\n" " " < /home/frappe/frappe-bench/sites/apps.txt'
}

validate_app_names() {
	local app
	for app in "$@"; do
		[[ "$app" =~ ^[a-zA-Z0-9_][a-zA-Z0-9_.-]*$ ]] || {
			echo "Unsafe application name in sites/apps.txt: $app" >&2
			exit 3
		}
	done
}

hook_manifest() {
	local container="$1"
	shift
	docker exec "$container" sh -lc '
		for app do
			file="/home/frappe/frappe-bench/apps/$app/$app/hooks.py"
			if [ -f "$file" ]; then
				printf "%s " "$app"
				sha256sum "$file" | awk "{print \$1}"
			else
				printf "%s MISSING\n" "$app"
			fi
		done
	' sh "$@"
}

version_manifest() {
	local container="$1"
	shift
	docker exec "$container" sh -lc '
		for app do
			file="/home/frappe/frappe-bench/apps/$app/$app/__init__.py"
			if [ -f "$file" ]; then
				version="$(sed -n "s/^__version__ = //p" "$file" | head -1)"
				printf "%s %s\n" "$app" "${version:-UNDECLARED}"
			else
				printf "%s MISSING\n" "$app"
			fi
		done
	' sh "$@"
}

drifted_apps() {
	local target="$1"
	shift
	local apps=("$@") canonical_file target_file app canonical_hash target_hash
	canonical_file="$(mktemp)"
	target_file="$(mktemp)"
	hook_manifest "$CANONICAL_CONTAINER" "${apps[@]}" > "$canonical_file"
	hook_manifest "$target" "${apps[@]}" > "$target_file"
	while read -r app canonical_hash; do
		target_hash="$(awk -v wanted="$app" '$1 == wanted { print $2 }' "$target_file")"
		[[ "$canonical_hash" == "$target_hash" ]] || printf '%s\n' "$app"
	done < "$canonical_file"
	rm -f -- "$canonical_file" "$target_file"
}

audit_hooks() {
	local apps=("$@") container manifest reference status=0
	reference="$(mktemp)"
	hook_manifest "$CANONICAL_CONTAINER" "${apps[@]}" > "$reference"
	echo "Canonical: $CANONICAL_CONTAINER"
	cat "$reference"
	for container in "${TARGETS[@]}"; do
		manifest="$(mktemp)"
		hook_manifest "$container" "${apps[@]}" > "$manifest"
		if cmp -s "$reference" "$manifest"; then
			echo "$container: hook parity OK"
		else
			echo "$container: HOOK DRIFT" >&2
			diff -u "$reference" "$manifest" || true
			status=1
		fi
		rm -f -- "$manifest"
	done
	rm -f -- "$reference"
	return "$status"
}

audit_versions() {
	local apps=("$@") container manifest reference status=0
	reference="$(mktemp)"
	version_manifest "$CANONICAL_CONTAINER" "${apps[@]}" > "$reference"
	for container in "${TARGETS[@]}"; do
		manifest="$(mktemp)"
		version_manifest "$container" "${apps[@]}" > "$manifest"
		if cmp -s "$reference" "$manifest"; then
			echo "$container: application versions OK"
		else
			echo "$container: APPLICATION VERSION DRIFT" >&2
			diff -u "$reference" "$manifest" || true
			status=1
		fi
		rm -f -- "$manifest"
	done
	rm -f -- "$reference"
	return "$status"
}

assert_cache_clean() {
	docker exec -u frappe "$CANONICAL_CONTAINER" sh -lc '
		cd /home/frappe/frappe-bench/sites
		site="$1"; shift
		../env/bin/python - "$site" "$@" <<"PY"
import sys
import frappe

site = sys.argv[1]
forbidden = sys.argv[2:]
frappe.init(site=site)
try:
    hooks = frappe.get_hooks()
    serialized = repr(hooks)
    found = [path for path in forbidden if path in serialized]
    if found:
        raise SystemExit("obsolete cached hooks: " + ", ".join(found))
    print("Frappe app_hooks cache is warm and contains no obsolete hook paths.")
finally:
    frappe.destroy()
PY
	' sh "$SITE" "${OBSOLETE_HOOKS[@]}"
}

warm_cache() {
	local container
	for container in "${TARGETS[@]}"; do
		if container_running "$container"; then
			echo "Refusing to rebuild app_hooks while $container is running." >&2
			return 1
		fi
	done
	docker exec -u frappe "$CANONICAL_CONTAINER" bench --site "$SITE" clear-cache
	assert_cache_clean
}

sync_runtime() {
	local apps=("$@") target stage backup drift app timestamp
	local changed_targets=()
	timestamp="$(date -u +%Y%m%dT%H%M%SZ)"

	rollback_sync() {
		local failed_status="$?" rollback_target rollback_backup
		trap - ERR
		echo "Synchronization failed; restoring packages already replaced in this run." >&2
		for rollback_target in "${changed_targets[@]}"; do
			docker start "$rollback_target" >/dev/null 2>&1 || true
			rollback_backup="$BENCH_ROOT/.runtime-parity-backup-$timestamp"
			docker exec -u root "$rollback_target" sh -lc '
				set -eu
				backup="$1"
				test -f "$backup/apps-replaced.txt"
				while IFS= read -r app; do
					case "$app" in (*[!a-zA-Z0-9_.-]*|"") exit 70;; esac
					current="/home/frappe/frappe-bench/apps/$app/$app"
					failed="$backup/$app.failed"
					mv "$current" "$failed"
					mv "$backup/$app" "$current"
				done < "$backup/apps-replaced.txt"
			' sh "$rollback_backup" || true
			docker restart "$rollback_target" >/dev/null 2>&1 || true
		done
		exit "$failed_status"
	}
	trap rollback_sync ERR

	for target in "${TARGETS[@]}"; do
		mapfile -t drift < <(drifted_apps "$target" "${apps[@]}")
		if (( ${#drift[@]} == 0 )); then
			echo "$target: already matches canonical hooks"
			continue
		fi
		validate_app_names "${drift[@]}"
		stage="$BENCH_ROOT/.runtime-parity-stage-$timestamp"
		backup="$BENCH_ROOT/.runtime-parity-backup-$timestamp"
		echo "$target: preserving and replacing drifted apps: ${drift[*]}"
		docker exec -u root "$target" sh -lc \
			'rm -rf -- "$1"; install -d -m 0755 -o frappe -g frappe "$1" "$2"' \
			sh "$stage" "$backup"

		paths=()
		for app in "${drift[@]}"; do paths+=("$app/$app"); done
		docker exec "$CANONICAL_CONTAINER" tar \
			--exclude='*/__pycache__' --exclude='*.pyc' --exclude='*.pyo' \
			-C "$APP_ROOT" -cf - "${paths[@]}" \
			| docker exec -i "$target" tar -C "$stage" -xf -
		docker exec -u frappe "$target" python -m compileall -q "$stage"

		docker exec -u root "$target" sh -lc '
			set -eu
			stage="$1"; backup="$2"; shift 2
			for app do
				old="/home/frappe/frappe-bench/apps/$app/$app"
				new="$stage/$app/$app"
				test -d "$old"; test -d "$new"
				mv "$old" "$backup/$app"
				mv "$new" "$old"
				chown -R frappe:frappe "$old"
			done
			printf "%s\n" "$@" > "$backup/apps-replaced.txt"
			rm -rf -- "$stage"
		' sh "$stage" "$backup" "${drift[@]}"
		changed_targets+=("$target")

		docker stop "$target" >/dev/null
	done

	for target in "${TARGETS[@]}"; do
		if container_running "$target"; then
			docker stop "$target" >/dev/null
		fi
	done
	warm_cache
	docker start "${TARGETS[@]}" >/dev/null
	sleep 3
	audit_hooks "${apps[@]}"
	audit_versions "${apps[@]}"
	assert_cache_clean
	trap - ERR
	echo "Runtime synchronization complete. In-container rollback directories use timestamp $timestamp."
}

require_containers
read -r -a APPS <<< "$(installed_apps)"
(( ${#APPS[@]} > 0 )) || { echo "No applications found in sites/apps.txt" >&2; exit 4; }
validate_app_names "${APPS[@]}"

case "$MODE" in
	audit)
		audit_hooks "${APPS[@]}"
		audit_versions "${APPS[@]}"
		;;
	verify)
		audit_hooks "${APPS[@]}"
		audit_versions "${APPS[@]}"
		assert_cache_clean
		;;
	sync)
		sync_runtime "${APPS[@]}"
		;;
	warm-cache)
		warm_cache
		;;
	-h|--help|help)
		usage
		;;
	*)
		usage >&2
		exit 64
		;;
esac
