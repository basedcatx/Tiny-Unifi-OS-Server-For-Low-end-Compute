#!/usr/bin/env bash
#
# free-resources.sh - stop the things that steal CPU/RAM from the controller.
#
# Usage: free-resources.sh [--host-only|--container-only] [--dry-run]

set -u

CONTAINER="uosserver"
DRY=0
SCOPE=both

for a in "$@"; do
    case "$a" in
    --dry-run) DRY=1 ;;
    --host-only) SCOPE=host ;;
    --container-only) SCOPE=container ;;
    -h | --help)
        sed -n '2,12p' "$0"
        exit 0
        ;;
    *)
        echo "unknown option: $a" >&2
        exit 2
        ;;
    esac
done

run() {
    if [ "$DRY" = 1 ]; then echo "  would: $*"; else "$@" >/dev/null 2>&1 || true; fi
}

say() { echo "[free-resources] $*"; }

host_side() {
    say "host: reclaiming CPU"

    # TT
    # Oracle Cloud Agent snap.  gomon + agent + oci-wlp + runcommand together
    for s in snap.oracle-cloud-agent.oracle-cloud-agent.service; do
        run systemctl stop "$s"
        run systemctl disable "$s"
        run systemctl mask "$s"
    done
    run pkill -f 'snap.oracle-cloud-agent'
    run pkill -f 'oci-wlp'

    # Enable this only if you do not use apache2
    # run systemctl stop apache2
    # run systemctl disable apache2

    for s in fwupd fwupd-refresh.timer iscsid ModemManager rpcbind \
        apt-daily.timer apt-daily-upgrade.timer; do
        run systemctl stop "$s"
        run systemctl disable "$s"
        run systemctl mask "$s"
    done

    run sysctl -w vm.swappiness=10
    say "host: done"
}

container_side() {
    say "container: reclaiming CPU/RAM"

    podman exec -i "$CONTAINER" bash -s <<'EOS' 2>/dev/null || true
set -u
say() { echo "[free-resources] $*"; }

for u in ulp-go.service ucs-agent.service unifi-directory.service \
         uid-agent.service unifi-identity-update.service; do
    systemctl stop "$u" 2>/dev/null
    systemctl disable "$u" 2>/dev/null
done

PG=/etc/postgresql/14/main/postgresql.conf
if [ -f "$PG" ] && ! grep -q '^max_connections = 20$' "$PG"; then
    sed -i 's/^max_connections = .*/max_connections = 20/' "$PG"
    systemctl reload postgresql@14-main 2>/dev/null || systemctl restart postgresql@14-main 2>/dev/null
fi

MC=/etc/mongod.conf
if [ -f "$MC" ] && ! grep -q 'wiredTigerCacheSizeGB' "$MC"; then
    printf '\nstorage:\n  dbStorage:\n    wiredTiger:\n      engineConfig:\n        wiredTigerCacheSizeGB: 0.15\n' >> "$MC"
    systemctl restart mongodb 2>/dev/null
fi
say "container: done"
EOS
}

[ "$SCOPE" = host ] || [ "$SCOPE" = both ] && host_side
[ "$SCOPE" = container ] || [ "$SCOPE" = both ] && container_side

cat <<'EOF'

Undo (per unit):   systemctl unmask <unit> && systemctl enable --now <unit>
Undo (threadpool): edit /etc/default/unifi-core, then systemctl restart unifi-core
EOF
