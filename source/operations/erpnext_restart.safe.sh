#!/usr/bin/env bash
set -Eeuo pipefail

VOLUME_ROOT="${ERPNEXT_VOLUME_ROOT:-/srv/erpnext}"
INTEGRITY_SCRIPT="$VOLUME_ROOT/frappe_runtime_integrity.sh"
NGINX_CONFIG="$VOLUME_ROOT/frappe_nginx_current.conf"
PUBLIC_HOST="${ERPNEXT_PUBLIC_HOST:-erp.example.com}"

[[ "$PUBLIC_HOST" =~ ^[A-Za-z0-9][A-Za-z0-9.-]{0,252}[A-Za-z0-9]$ ]] || {
	echo "Unsafe ERPNEXT_PUBLIC_HOST value: $PUBLIC_HOST" >&2
	exit 2
}

containers_stop_order=(
	frappe_docker-frontend-1
	frappe_docker-websocket-1
	frappe_docker-scheduler-1
	frappe_docker-queue-long-1
	frappe_docker-queue-short-1
	frappe_docker-backend-1
	frappe_docker-redis-queue-1
	frappe_docker-redis-cache-1
	frappe_docker-db-1
)

wait_for_health() {
	local container="$1" attempts="${2:-60}" status
	for ((attempt=1; attempt<=attempts; attempt++)); do
		status="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$container")"
		case "$status" in
			healthy|running) return 0 ;;
			unhealthy|exited|dead) echo "$container entered state $status" >&2; return 1 ;;
		esac
		sleep 1
	done
	echo "Timed out waiting for $container" >&2
	return 1
}

recover_web_on_error() {
	local status="$?"
	trap - ERR
	echo "Restart did not complete. Starting the minimum web path; background runtimes remain stopped until integrity is verified." >&2
	docker start frappe_docker-db-1 frappe_docker-redis-cache-1 frappe_docker-redis-queue-1 >/dev/null 2>&1 || true
	docker start frappe_docker-backend-1 frappe_docker-websocket-1 frappe_docker-frontend-1 >/dev/null 2>&1 || true
	exit "$status"
}

[[ -x "$INTEGRITY_SCRIPT" ]] || {
	echo "Missing runtime integrity guard: $INTEGRITY_SCRIPT" >&2
	exit 2
}

read -r -p "Do you want to restart the ERPNext containers? (y/n): " answer
case "$answer" in
	[Yy]*) ;;
	*) echo "Exiting without changes."; exit 0 ;;
esac

echo "Checking Frappe application and cached-hook integrity before restart..."
"$INTEGRITY_SCRIPT" verify

trap recover_web_on_error ERR
echo "Stopping ERPNext in dependency-safe order..."
for container in "${containers_stop_order[@]}"; do
	docker stop "$container" >/dev/null
done

echo "Starting database and Redis first..."
docker start frappe_docker-db-1 >/dev/null
wait_for_health frappe_docker-db-1 90
docker start frappe_docker-redis-cache-1 frappe_docker-redis-queue-1 >/dev/null
wait_for_health frappe_docker-redis-cache-1 30
wait_for_health frappe_docker-redis-queue-1 30

echo "Starting the canonical backend and rebuilding app_hooks before any worker can write the cache..."
docker start frappe_docker-backend-1 >/dev/null
wait_for_health frappe_docker-backend-1 30
"$INTEGRITY_SCRIPT" warm-cache

echo "Starting synchronized background runtimes, websocket, and frontend..."
docker start \
	frappe_docker-queue-short-1 \
	frappe_docker-queue-long-1 \
	frappe_docker-scheduler-1 \
	frappe_docker-websocket-1 \
	frappe_docker-frontend-1 >/dev/null
wait_for_health frappe_docker-frontend-1 30

if [[ -f "$NGINX_CONFIG" ]]; then
	echo "Restoring the persistent nginx configuration..."
	docker cp "$NGINX_CONFIG" frappe_docker-frontend-1:/etc/nginx/conf.d/frappe.conf >/dev/null
	docker exec -u root frappe_docker-frontend-1 sh -lc '
		set -eu
		for dir in body proxy fastcgi uwsgi scgi; do
			target="/var/lib/nginx/$dir"
			test -d "$target"
			chown frappe:frappe "$target"
			chmod 0700 "$target"
		done
	'
	docker exec -u frappe frappe_docker-frontend-1 nginx -t
	docker exec -u frappe frappe_docker-frontend-1 nginx -s reload
fi

echo "Refreshing host aliases and the optional backend SSHFS mount..."
sed -i '/### Added by docker hostname ###/,/### End of docker hostname ###/d' /etc/hosts
{
	printf '%s\n' '### Added by docker hostname ###'
	printf '%s erpnext_db\n' "$(docker inspect -f '{{range.NetworkSettings.Networks}}{{println .IPAddress}}{{end}}' frappe_docker-db-1 | awk 'NF {print $1; exit}')"
	printf '%s erpnext_backend\n' "$(docker inspect -f '{{range.NetworkSettings.Networks}}{{println .IPAddress}}{{end}}' frappe_docker-backend-1 | awk 'NF {print $1; exit}')"
	printf '%s\n' '### End of docker hostname ###'
} >> /etc/hosts
docker exec -u root frappe_docker-backend-1 sh -lc 'pgrep -x sshd >/dev/null || /usr/sbin/sshd'
docker exec -u root frappe_docker-websocket-1 sh -lc \
	'sed -i "/[[:space:]]$1$/d" /etc/hosts; printf "%s %s\n" "172.17.0.1" "$1" >> /etc/hosts' \
	sh "$PUBLIC_HOST"
if [[ -x "$VOLUME_ROOT/sshmount_docker_backend.sh" ]]; then
	"$VOLUME_ROOT/sshmount_docker_backend.sh" || echo "Warning: ERPNext is running, but the optional SSHFS remount failed." >&2
fi

"$INTEGRITY_SCRIPT" verify
trap - ERR
echo "ERPNext restart completed with synchronized hooks and a backend-built cache."
