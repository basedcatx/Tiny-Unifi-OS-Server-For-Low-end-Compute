#!/usr/bin/env bash
#
# bootstrap.sh - UniFi OS Server on a small VPS.
#
# Detects what is already present and does the minimum:
#
#   nothing installed          -> install, tune, verify
#   installed, not healthy     -> repair, restart, verify
#   installed, healthy         -> verify only (no restarts)
#
# Usage:
#   sudo ./scripts/bootstrap.sh                 # auto
#   sudo ./scripts/bootstrap.sh --dry-run       # show, change nothing
#   sudo ./scripts/bootstrap.sh --repair        # never install
#   sudo ./scripts/bootstrap.sh --verify        # read-only
#   sudo ./scripts/bootstrap.sh --repair --no-restart   # tune, no outage
#   sudo ./scripts/bootstrap.sh --install \
#        --payload-tarball uosserver-payload-v5.1.42.tar.gz \
#        --image-tarball   uosserver-image.tar.gz
#
# Exit codes: 0 ok, 1 failed, 2 bad usage, 3 missing prerequisites.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CONTAINER="uosserver"
STATE_DIR="/var/lib/uosserver"
UNIFI_CORE_PORT=11081
UNIFI_WEB_PORT=8443

# See docs/TUNING.md before changing any of these.
APP_VERSION="5.1.42"
CONTAINER_VERSION="c9603dec9010"
IMAGE_REF="docker.io/library/uosserver:${CONTAINER_VERSION}"
UV_THREADPOOL=16
NODE_HEAP_MB=800
MEMORY_MAX=1024M
JVM_XMX=384m
PIDS_MAX=2048
SWAP_MB=2048

DRY_RUN=0
FORCE=0
NO_RESTART=0
MODE=auto
IMAGE_TARBALL=""
PAYLOAD_TARBALL=""
CORE_TIMEOUT=900  # seconds to wait for unifi-core to bind 11081
JAVA_TIMEOUT=1200 # seconds to wait for the controller to bind 8443

# ---------------------------------------------------------------------------
# output helpers
# ---------------------------------------------------------------------------
C_OK=""
C_BAD=""
C_DIM=""
C_OFF=""
if [ -t 1 ]; then
    C_OK=$'\033[32m'
    C_BAD=$'\033[31m'
    C_DIM=$'\033[2m'
    C_OFF=$'\033[0m'
fi

stage() { printf '\n%s== %s ==%s\n' "$C_DIM" "$*" "$C_OFF"; }
ok() { printf '  %s[ok]%s   %s\n' "$C_OK" "$C_OFF" "$*"; }
skip() { printf '  %s[skip]%s %s\n' "$C_DIM" "$C_OFF" "$*"; }
fix() { printf '  %s[fix]%s  %s\n' "$C_OK" "$C_OFF" "$*"; }
warn() { printf '  [warn] %s\n' "$*"; }
die() {
    printf '%s[FAIL]%s %s\n' "$C_BAD" "$C_OFF" "$*" >&2
    exit "${2:-1}"
}

run() {
    if [ "$DRY_RUN" = 1 ]; then
        printf '  %s[would]%s %s\n' "$C_DIM" "$C_OFF" "$*"
        return 0
    fi
    "$@"
}

run_sh() {
    if [ "$DRY_RUN" = 1 ]; then
        printf '  %s[would]%s %s\n' "$C_DIM" "$C_OFF" "$1"
        return 0
    fi
    bash -c "$1"
}

usage() {
    sed -n '3,22p' "$0"
    exit 0
}

while [ $# -gt 0 ]; do
    case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --repair) MODE=repair ;;
    --verify) MODE=verify ;;
    --install) MODE=install ;;
    --force) FORCE=1 ;;
    --no-restart) NO_RESTART=1 ;;
    --image-tarball)
        IMAGE_TARBALL="${2:-}"
        shift
        ;;
    --payload-tarball)
        PAYLOAD_TARBALL="${2:-}"
        shift
        ;;
    --core-timeout)
        CORE_TIMEOUT="${2:-900}"
        shift
        ;;
    --java-timeout)
        JAVA_TIMEOUT="${2:-1200}"
        shift
        ;;
    -h | --help) usage ;;
    *)
        printf 'unknown option: %s\n' "$1" >&2
        exit 2
        ;;
    esac
    shift
done

[ "$(id -u)" -eq 0 ] || die "must run as root (use sudo)" 2

pod() {
    if [ "$(id -un 2>/dev/null)" = "uosserver" ]; then
        (cd /tmp && podman "$@")
    else
        (cd /tmp && sudo -n -u uosserver podman "$@")
    fi
}

have_install() { [ -x "$STATE_DIR/bin/uosserver-service" ]; }
have_container() { command -v podman >/dev/null 2>&1 && pod container exists "$CONTAINER" >/dev/null 2>&1; }

container_running() {
    [ "$(pod inspect "$CONTAINER" --format '{{.State.Status}}' 2>/dev/null)" = running ]
}

in_c() { pod exec -i "$CONTAINER" bash -c "$1" 2>/dev/null; }

core_up() { in_c "ss -tuln 2>/dev/null | grep -qE '[:.]${UNIFI_CORE_PORT}[[:space:]]'"; }
java_up() { in_c "ss -tuln 2>/dev/null | grep -qE '[:.]${UNIFI_WEB_PORT}[[:space:]]'"; }

detect_mode() {
    if [ "$MODE" != auto ]; then return; fi
    if ! have_install; then
        MODE=install
    elif ! have_container; then
        MODE=repair
    elif ! container_running; then
        MODE=repair
    elif core_up && java_up; then
        MODE=verify
    else
        MODE=repair
    fi
}

preflight() {
    stage "preflight"
    ok "root"
    ok "repo $REPO_DIR"

    local arch
    arch=$(uname -m)
    if [ "$arch" != x86_64 ]; then die "unsupported architecture: $arch (needs x86_64)" 3; fi
    ok "arch $arch"

    local mem_kb mem_mb
    mem_kb=$(awk '/MemTotal/{print $2}' /proc/meminfo)
    mem_mb=$((mem_kb / 1024))
    if [ "$mem_mb" -lt 700 ]; then
        die "$mem_mb MB RAM is below the practical floor (need >= 900 MB, 1 GB recommended). 512 MB will not work." 3
    elif [ "$mem_mb" -lt 900 ]; then
        warn "$mem_mb MB RAM is tight; 1 GB is the tested minimum."
    else
        ok "memory ${mem_mb} MB"
    fi

    local free_gb
    free_gb=$(df -BG --output=avail / | tail -1 | tr -dc '0-9')
    if [ "${free_gb:-0}" -lt 8 ]; then die "need >= 8 GB free disk (have ${free_gb}G)" 3; fi
    ok "disk ${free_gb}G free"

    if ! command -v systemctl >/dev/null 2>&1; then die "systemd is required" 3; fi
    ok "systemd"
}

ensure_swap() {
    stage "swap"
    local cur
    cur=$(free -m | awk '/^Swap:/{print $2}')
    if [ "${cur:-0}" -ge 1024 ]; then
        ok "swap ${cur} MB"
        return
    fi
    fix "creating ${SWAP_MB} MB swapfile"
    if [ "$DRY_RUN" = 1 ]; then
        skip "would create /swapfile"
        return
    fi
    if [ ! -f /swapfile ]; then
        fallocate -l "${SWAP_MB}M" /swapfile 2>/dev/null ||
            dd if=/dev/zero of=/swapfile bs=1M count="$SWAP_MB" status=none
        chmod 600 /swapfile
        mkswap /swapfile >/dev/null
    fi
    swapon /swapfile 2>/dev/null || true
    grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >>/etc/fstab
    sysctl -qw vm.swappiness=10
    ok "swap $(free -m | awk '/^Swap:/{print $2}') MB"
}

install_deps() {
    stage "dependencies"
    local missing=()
    # NB: the "uidmap" package installs newuidmap/newgidmap, not a binary
    # called "uidmap".  Check the real names, or every run tries to apt-install.
    for p in podman pasta newuidmap slirp4netns fuse-overlayfs curl; do
        command -v "$p" >/dev/null 2>&1 || missing+=("$p")
    done
    if [ ${#missing[@]} -eq 0 ]; then
        ok "podman toolchain present"
        return
    fi

    fix "installing: ${missing[*]}"
    if [ "$DRY_RUN" = 1 ]; then
        skip "would apt-get install"
        return
    fi
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq podman passt uidmap slirp4netns fuse-overlayfs curl ca-certificates
    ok "podman $(podman --version | awk '{print $3}')"
}

install_payload() {
    stage "UniFi OS Server payload"
    if have_install; then
        ok "$STATE_DIR/bin/uosserver-service present"
        return
    fi

    if [ -z "$PAYLOAD_TARBALL" ]; then
        cat <<EOF
  ${C_BAD}[FAIL]${C_OFF} no UniFi OS Server installation found, and no payload given.

  This script can reproduce every fix, but it cannot invent Ubiquiti's
  binaries.  On a fresh VPS you need BOTH of these from a working box:

    1) payload  (~13 MB)   - host binaries + units
         tar czf uosserver-payload-v${APP_VERSION}.tar.gz \\
             var/lib/uosserver/bin var/lib/uosserver/*.json \\
             etc/systemd/system/uosserver.service \\
             etc/systemd/system/uosserver-updater.service

    2) image    (~1.9 GB)  - the container itself
         podman save ${IMAGE_REF} | gzip > uosserver-image.tar.gz

  Then:
     sudo ./scripts/bootstrap.sh --install \\
         --payload-tarball ./uosserver-payload-v${APP_VERSION}.tar.gz \\
         --image-tarball   ./uosserver-image.tar.gz
EOF
        exit 3
    fi

    [ -f "$PAYLOAD_TARBALL" ] || die "payload not found: $PAYLOAD_TARBALL" 3
    fix "extracting $PAYLOAD_TARBALL"
    run tar xzf "$PAYLOAD_TARBALL" -C /
    chmod 755 "$STATE_DIR/bin/"* 2>/dev/null || true
    ok "payload installed"
}

install_units() {
    stage "systemd units"
    local changed=0
    for u in uosserver.service uosserver-updater.service; do
        if [ ! -f "/etc/systemd/system/$u" ]; then
            run install -m 644 "$REPO_DIR/install/$u" "/etc/systemd/system/$u"
            fix "$u"
            changed=1
        else
            skip "$u"
        fi
    done
    if [ "$changed" = 1 ] && [ "$DRY_RUN" = 0 ]; then systemctl daemon-reload; fi

    # uosserver user, uid 1002 on the reference box
    if id uosserver >/dev/null 2>&1; then
        ok "user uosserver (uid $(id -u uosserver))"
    else
        fix "creating user uosserver"
        run useradd --system --create-home --uid 1002 --shell /bin/bash uosserver
    fi

    # server.conf
    if [ -f "$STATE_DIR/server.conf" ]; then
        ok "server.conf present"
    else
        fix "generating server.conf"
        local uuid
        uuid=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "00000000-0000-4000-8000-000000000000")
        if [ "$DRY_RUN" = 0 ]; then
            sed -e "s|__UOS_UUID__|$uuid|" \
                -e "s|__CONTAINER_VERSION__|$CONTAINER_VERSION|" \
                -e "s|__APP_VERSION__|$APP_VERSION|" \
                "$REPO_DIR/install/server.conf.tpl" >"$STATE_DIR/server.conf"
            chown root:root "$STATE_DIR/server.conf"
            chmod 640 "$STATE_DIR/server.conf"
        fi
    fi
}

install_image() {
    stage "container image"
    if pod image exists "$IMAGE_REF" >/dev/null 2>&1; then
        ok "$IMAGE_REF present"
        return
    fi
    if [ -z "$IMAGE_TARBALL" ]; then
        die "$IMAGE_REF missing and no --image-tarball given (see docs, it is ~1.9 GB)" 3
    fi
    [ -f "$IMAGE_TARBALL" ] || die "image tarball not found: $IMAGE_TARBALL" 3
    fix "loading $IMAGE_TARBALL (this takes a while)"
    if [ "$DRY_RUN" = 1 ]; then skip "would podman load"; else
        if [ "${IMAGE_TARBALL%.gz}" != "$IMAGE_TARBALL" ]; then
            gunzip -c "$IMAGE_TARBALL" | pod load
        else
            pod load -i "$IMAGE_TARBALL"
        fi
    fi
    pod image exists "$IMAGE_REF" >/dev/null 2>&1 && ok "image loaded" || die "image load failed" 1
}

start_supervisor() {
    stage "supervisor"
    run systemctl daemon-reload
    run systemctl enable uosserver-updater.service
    run systemctl enable uosserver.service
    if container_running; then
        ok "container already running"
    else
        fix "starting uosserver"
        run systemctl start uosserver-updater.service
        run systemctl start uosserver.service
    fi

    [ "$DRY_RUN" = 1 ] && {
        skip "would wait for container"
        return
    }

    local i
    for i in $(seq 1 60); do
        container_running && break
        sleep 5
    done
    container_running && ok "container running" || die "container did not start" 1
}

tune_host() {
    stage "host tuning"
    local uid f changed=0
    uid=$(id -u uosserver)

    for f in /sys/fs/cgroup/user.slice/user-"$uid".slice/user@"$uid".service/user.slice/libpod-*/pids.max; do
        [ -e "$f" ] || continue
        if [ "$(cat "$f" 2>/dev/null)" != "$PIDS_MAX" ]; then
            run_sh "echo $PIDS_MAX > '$f'" && {
                fix "pids.max $PIDS_MAX"
                changed=1
            }
        fi
    done
    [ "$changed" = 0 ] && ok "pids.max already $PIDS_MAX"

    if command -v sysctl >/dev/null 2>&1; then
        local mmc
        mmc=$(sysctl -n vm.max_map_count 2>/dev/null || echo 0)
        if [ "${mmc:-0}" -lt 262144 ]; then
            run sysctl -qw vm.max_map_count=1048576
            grep -q '^vm.max_map_count' /etc/sysctl.conf 2>/dev/null ||
                echo 'vm.max_map_count=1048576' >>/etc/sysctl.conf
            fix "vm.max_map_count=1048576"
        else
            ok "vm.max_map_count $mmc"
        fi
        run sysctl -qw vm.swappiness=10
    fi

    if [ -x "$REPO_DIR/scripts/free-resources.sh" ]; then
        if [ "$DRY_RUN" = 1 ]; then
            run "$REPO_DIR/scripts/free-resources.sh" --dry-run --host-only
        else
            "$REPO_DIR/scripts/free-resources.sh" --host-only >/dev/null 2>&1
            ok "disabled idle CPU consumers (see README)"
        fi
    fi
}

tune_container() {
    stage "container tuning"
    if [ "$DRY_RUN" = 1 ]; then
        skip "would apply drop-ins + threadpool + heap"
        return
    fi

    pod exec -i "$CONTAINER" bash -s <<EOS
set -u
D=/etc/systemd/system/unifi-core.service.d
mkdir -p "\$D"

cat > "\$D/memory.conf" <<'CONF'
[Service]
MemoryMax=$MEMORY_MAX
MemorySwapMax=512M
CONF

cat > "\$D/exec-heap.conf" <<'CONF'
[Service]
ExecStart=
ExecStart=/usr/bin/node24 --expose-gc --max-old-space-size=$NODE_HEAP_MB --openssl-legacy-provider --no-network-family-autoselection --dns-result-order=ipv4first /usr/share/unifi-core/app/service.js
CONF

cat > "\$D/timeout.conf" <<'CONF'
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

# libuv threadpool: 256 threads = 269 pids, which is what breaks everything.
if [ -f /etc/default/unifi-core ]; then
    sed -i 's/^UV_THREADPOOL_SIZE=.*/UV_THREADPOOL_SIZE=$UV_THREADPOOL/' /etc/default/unifi-core
fi
# JVM heap.  No inline comments in this file.
if [ -f /etc/default/unifi ] && ! grep -q -- "-Xmx$JVM_XMX" /etc/default/unifi; then
    sed -i 's|-XX:MaxRAMPercentage=70.0|-XX:MaxRAMPercentage=70.0 -Xmx$JVM_XMX|' /etc/default/unifi
fi

# The pre-start hook copies into this directory without creating it.
mkdir -p /data/unifi-core/config/http

systemctl daemon-reload
chown -R unifi-core:unifi-core /data/unifi-core 2>/dev/null
chown -R unifi:unifi /data/unifi 2>/dev/null
echo applied
EOS

    if [ $? -eq 0 ]; then ok "drop-ins + threadpool=$UV_THREADPOOL + heap=${NODE_HEAP_MB}m + jvm=$JVM_XMX"; else die "container tuning failed" 1; fi

    # re-raise pids after the container settled
    local uid f
    uid=$(id -u uosserver)
    for f in /sys/fs/cgroup/user.slice/user-"$uid".slice/user@"$uid".service/user.slice/libpod-*/pids.max; do
        [ -e "$f" ] && echo "$PIDS_MAX" >"$f" 2>/dev/null
    done
}

install_repair_unit() {
    stage "repair + guard units"
    local changed=0 u

    if ! cmp -s "$REPO_DIR/scripts/repair.sh" /usr/local/bin/uosserver-repair.sh 2>/dev/null; then
        run install -m 755 "$REPO_DIR/scripts/repair.sh" /usr/local/bin/uosserver-repair.sh
        fix "uosserver-repair.sh"
        changed=1
    fi
    if ! cmp -s "$REPO_DIR/scripts/pids-guard.sh" /usr/local/bin/uosserver-pids.sh 2>/dev/null; then
        run install -m 755 "$REPO_DIR/scripts/pids-guard.sh" /usr/local/bin/uosserver-pids.sh
        fix "uosserver-pids.sh"
        changed=1
    fi
    for u in uosserver-repair.service uosserver-pids.service uosserver-pids.timer uosserver-repair.timer; do
        if ! cmp -s "$REPO_DIR/install/$u" "/etc/systemd/system/$u" 2>/dev/null; then
            run install -m 644 "$REPO_DIR/install/$u" "/etc/systemd/system/$u"
            fix "$u"
            changed=1
        fi
    done
    [ "$changed" = 0 ] && ok "guard units already current"

    run systemctl daemon-reload
    run systemctl enable uosserver-repair.service
    run systemctl enable --now uosserver-pids.timer
    run systemctl enable --now uosserver-repair.timer
    run systemctl start uosserver-pids.service
    ok "guards active (pids every 30s, repair every 5min)"
}

restart_stack() {
    stage "restart"
    if [ "$NO_RESTART" = 1 ]; then
        skip "--no-restart given; left services untouched"
        return
    fi
    if [ "$DRY_RUN" = 1 ]; then
        skip "would restart unifi-core then unifi"
        return
    fi

    in_c "systemctl reset-failed unifi-core; systemctl restart unifi-core" >/dev/null
    fix "unifi-core restarting"

    local i
    for i in $(seq 1 $((CORE_TIMEOUT / 5))); do
        if core_up; then
            ok "unifi-core listening on $UNIFI_CORE_PORT (after $((i * 5))s)"
            break
        fi
        sleep 5
        if [ "$i" -eq $((CORE_TIMEOUT / 5)) ]; then
            warn "unifi-core did not bind $UNIFI_CORE_PORT within ${CORE_TIMEOUT}s"
            in_c "systemctl show unifi-core -p ActiveState -p SubState -p TasksCurrent"
        fi
    done

    in_c "systemctl reset-failed unifi; systemctl restart unifi" >/dev/null
    fix "unifi (java) restarting"

    for i in $(seq 1 $((JAVA_TIMEOUT / 5))); do
        if java_up; then
            ok "controller listening on $UNIFI_WEB_PORT (after $((i * 5))s)"
            break
        fi
        sleep 5
        if [ "$i" -eq $((JAVA_TIMEOUT / 5)) ]; then
            warn "controller did not bind $UNIFI_WEB_PORT within ${JAVA_TIMEOUT}s"
            in_c "tail -20 /data/unifi/logs/server.log"
        fi
    done
}

do_verify() {
    stage "verify"
    if [ -x "$REPO_DIR/scripts/verify.sh" ]; then
        "$REPO_DIR/scripts/verify.sh"
        return $?
    fi
    warn "scripts/verify.sh not found"
    return 0
}

main() {
    detect_mode
    printf '  mode: %s%s\n' "$MODE" "$([ "$DRY_RUN" = 1 ] && echo ' (dry run)')"

    preflight
    ensure_swap

    case "$MODE" in
    install)
        install_deps
        install_payload
        install_units
        install_image
        start_supervisor
        tune_host
        tune_container
        install_repair_unit
        restart_stack
        do_verify
        ;;
    repair)
        install_deps
        if ! have_install; then
            install_payload
            install_units
            install_image
        fi
        start_supervisor
        tune_host
        tune_container
        install_repair_unit
        restart_stack
        do_verify
        ;;
    verify)
        do_verify
        ;;
    esac

    stage "summary"
    printf '  repo    %s\n' "$REPO_DIR"
    printf '  mode    %s\n' "$MODE"
    printf '  web ui  https://<this-host>:11443/   (container 443 -> host 11443)\n'
    printf '  core    http://127.0.0.1:11081/api/system\n'
    if command -v podman >/dev/null 2>&1; then
        printf '  health  %s\n' "$(pod inspect "$CONTAINER" --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}n/a{{end}}' 2>/dev/null)"
    fi
    echo
}

main
