#!/usr/bin/env bash
#
# repair.sh - re-apply every fix that lives in the container's writable layer.
#
# /data is a persistent podman volume, but /etc/default/*, the systemd drop-ins
# and /usr/share/unifi-core all live in the overlay, which uosserver-updater
# wipes whenever it re-creates the container.  This script puts them back.
#
# Runs as the "uosserver" user (rootless podman).  Safe to run repeatedly.
#
# Installed as /usr/local/bin/uosserver-repair.sh and driven by
# uosserver-repair.service.

set -u

CONTAINER="uosserver"
VOLUME="/home/uosserver/.local/share/containers/storage/volumes/uosserver_data/_data"
LOG_TAG="uosserver-repair"

log() {
    logger -t "$LOG_TAG" -- "$*" 2>/dev/null
    echo "[$LOG_TAG] $*"
}

# -i is essential: overlay_fixes() feeds bash its script on stdin.  Without it
# "bash -s" reads EOF immediately and silently does nothing at all, which is
in_container() {
    podman exec -i "$CONTAINER" bash -c "$1" 2>/dev/null
}

wait_for_container() {
    local i
    for i in $(seq 1 60); do
        if podman exec "$CONTAINER" true >/dev/null 2>&1; then
            return 0
        fi
        sleep 5
    done
    return 1
}

raise_container_pids() {
    local uid f
    uid=$(id -u)
    for f in /sys/fs/cgroup/user.slice/user-"${uid}".slice/user@"${uid}".service/user.slice/libpod-*/pids.max; do
        [ -e "$f" ] || continue
        if [ "$(cat "$f" 2>/dev/null)" != "2048" ]; then
            if echo 2048 >"$f" 2>/dev/null; then
                log "raised pids.max -> 2048 ($(dirname "$f"))"
            else
                log "WARNING: could not raise $f"
            fi
        fi
    done
}

ensure_persistent_dirs() {
    local d
    for d in \
        "$VOLUME/unifi-core/config/http" \
        "$VOLUME/unifi-core/logs" \
        "$VOLUME/unifi-core/config/overrides" \
        "$VOLUME/unifi-core/config/cache" \
        "$VOLUME/unifi-core/config/apps"; do
        if [ ! -d "$d" ]; then
            mkdir -p "$d" 2>/dev/null && log "created $d"
        fi
    done
}

overlay_fixes() {
    in_container 'bash -s' <<'EOS'
set -u

F=/etc/default/unifi-core
if [ -f "$F" ] && ! grep -q '^UV_THREADPOOL_SIZE=16$' "$F"; then
    sed -i 's/^UV_THREADPOOL_SIZE=.*/UV_THREADPOOL_SIZE=16/' "$F"
    echo "threadpool-trimmed"
fi

J=/etc/default/unifi
if [ -f "$J" ] && ! grep -q -- "-Xmx384m" "$J"; then
    cp -n "$J" "$J.orig" 2>/dev/null || true
    sed -i 's|-XX:MaxRAMPercentage=70.0|-XX:MaxRAMPercentage=70.0 -Xmx384m|' "$J"
    echo "jvm-heap-capped"
fi

D=/etc/systemd/system/unifi-core.service.d
mkdir -p "$D"

cat > "$D/memory.conf" <<'CONF'
[Service]
MemoryMax=1024M
MemorySwapMax=512M
CONF

cat > "$D/exec-heap.conf" <<'CONF'
[Service]
ExecStart=
ExecStart=/usr/bin/node24 --expose-gc --max-old-space-size=800 --openssl-legacy-provider --no-network-family-autoselection --dns-result-order=ipv4first /usr/share/unifi-core/app/service.js
CONF

cat > "$D/timeout.conf" <<'CONF'
[Service]
TimeoutStartSec=20min
TimeoutStopSec=30s
WatchdogSec=infinity
TasksMax=4096
LimitNPROC=8192
CONF

mkdir -p /etc/systemd/system/unifi.service.d
cat > /etc/systemd/system/unifi.service.d/timeout.conf <<'CONF'
[Service]
TimeoutStartSec=20min
TimeoutStopSec=30s
KillMode=control-group
CONF

systemctl daemon-reload
echo "dropins-applied"

chown -R unifi-core:unifi-core /data/unifi-core 2>/dev/null
chown -R unifi:unifi /data/unifi 2>/dev/null
echo "ownership-ok"
EOS
}

report_status() {
    in_container 'systemctl show unifi-core -p ActiveState -p SubState -p NRestarts
systemctl show unifi -p ActiveState -p SubState
systemctl show unifi-core -p TasksCurrent
ss -tuln | grep -E "(11081|11084|8080|8443)" || true' | sed 's/^/    /'
}

main() {
    log "repair starting"
    ensure_persistent_dirs
    if wait_for_container; then
        log "container is up"
        raise_container_pids
        overlay_fixes | while read -r line; do log "$line"; done
        sleep 5
        report_status | while read -r line; do log "$line"; done
    else
        log "ERROR: container did not come up in time"
        return 1
    fi
    log "repair done"
    return 0
}

main "$@"
