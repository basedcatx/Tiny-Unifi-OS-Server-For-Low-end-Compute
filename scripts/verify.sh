#!/usr/bin/env bash
#
# verify.sh - end-to-end health check.  Read-only.
#
# Usage: verify.sh [--wait SECONDS]
# Exit:  0 healthy, 1 not healthy, 2 cannot inspect

set -u

CONTAINER="uosserver"
WAIT=0

while [ $# -gt 0 ]; do
    case "$1" in
    --wait)
        WAIT="${2:-0}"
        shift 2
        ;;
    -h | --help)
        sed -n '2,8p' "$0"
        exit 0
        ;;
    *)
        echo "unknown option: $1" >&2
        exit 2
        ;;
    esac
done

PASS=0
FAIL=0
info() { printf '  %-34s %s\n' "$1" "$2"; }
ok() {
    printf '  [ok]   %-27s %s\n' "$1" "$2"
    PASS=$((PASS + 1))
}
bad() {
    printf '  [FAIL] %-27s %s\n' "$1" "$2"
    FAIL=$((FAIL + 1))
}

pod() {
    if [ "$(id -un 2>/dev/null)" = "uosserver" ]; then
        (cd /tmp && podman "$@")
    else
        (cd /tmp && sudo -n -u uosserver podman "$@")
    fi
}

uid=$(id -u uosserver 2>/dev/null || echo 1002)

echo "== container =="
if ! pod container exists "$CONTAINER" 2>/dev/null; then
    bad "container" "does not exist"
    echo "RESULT: FAIL"
    exit 1
fi
state=$(pod inspect "$CONTAINER" --format '{{.State.Status}}' 2>/dev/null)
health=$(pod inspect "$CONTAINER" --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' 2>/dev/null)
info "status" "$state"
if [ "$state" = running ]; then ok "container running" "$state"; else bad "container running" "$state"; fi
if [ "$health" = healthy ] || [ "$health" = none ]; then ok "container health" "$health"; else bad "container health" "$health"; fi

echo "== cgroup limits =="
pmax=""
for f in /sys/fs/cgroup/user.slice/user-"$uid".slice/user@"$uid".service/user.slice/libpod-*/pids.max; do
    [ -e "$f" ] && pmax=$(cat "$f")
done
pcur=""
for f in /sys/fs/cgroup/user.slice/user-"$uid".slice/user@"$uid".service/user.slice/libpod-*/pids.current; do
    [ -e "$f" ] && pcur=$(cat "$f")
done
info "pids.max / pids.current" "${pmax:-?} / ${pcur:-?}"
if [ "${pmax:-0}" -ge 1024 ] 2>/dev/null; then ok "pids.max" "$pmax"; else bad "pids.max" "${pmax:-missing} (want >=1024)"; fi

echo "== services (inside container) =="
svc_out=$(
    pod exec -i "$CONTAINER" bash -s 2>/dev/null <<'EOS'
for u in unifi-core unifi nginx mongodb postgresql@14-main; do
    printf '%s|%s|%s\n' "$u" \
        "$(systemctl show "$u" -p ActiveState --value 2>/dev/null)" \
        "$(systemctl show "$u" -p SubState --value 2>/dev/null)"
done
printf 'threads|%s\n' "$(systemctl show unifi-core -p TasksCurrent --value 2>/dev/null)"
printf 'memmax|%s\n'  "$(systemctl show unifi-core -p MemoryMax --value 2>/dev/null)"
printf 'tpool|%s\n'   "$(grep -h '^UV_THREADPOOL_SIZE' /etc/default/unifi-core 2>/dev/null | cut -d= -f2)"
EOS
)

threads=""
memmax=""
tpool=""
while IFS='|' read -r a b c; do
    case "$a" in
    threads) threads="$b" ;;
    memmax) memmax="$b" ;;
    tpool) tpool="$b" ;;
    *) if [ "$b" = active ]; then ok "$a" "$b/$c"; else bad "$a" "$b/$c"; fi ;;
    esac
done <<<"$svc_out"

info "unifi-core threads" "${threads:-?}"
if [ "${threads:-0}" -le 80 ] 2>/dev/null; then ok "thread count" "$threads"; else bad "thread count" "$threads (want <=80, stock is 269)"; fi
info "unifi-core MemoryMax" "${memmax:-?}"
if [ "${memmax:-0}" -ge 1073741824 ] 2>/dev/null; then ok "MemoryMax" "$memmax"; else bad "MemoryMax" "${memmax:-?} (want >=1024M)"; fi
info "UV_THREADPOOL_SIZE" "${tpool:-?}"
if [ "${tpool:-999}" -le 32 ] 2>/dev/null; then ok "UV_THREADPOOL_SIZE" "$tpool"; else bad "UV_THREADPOOL_SIZE" "${tpool:-?} (want <=32)"; fi

echo "== listeners =="
list=$(pod exec -i "$CONTAINER" bash -c 'ss -tuln 2>/dev/null' 2>/dev/null)
for p in 11081 11084 8080 8443; do
    if echo "$list" | grep -qE "[:.]${p}[[:space:]]"; then ok "port $p" "listening"; else bad "port $p" "not listening"; fi
done

echo "== endpoints =="
code=$(pod exec -i "$CONTAINER" bash -c 'curl -s -m 8 -o /dev/null -w "%{http_code}" http://127.0.0.1:11081/api/system' 2>/dev/null)
if [ "$code" = 200 ]; then ok "core api/system" "$code"; else bad "core api/system" "${code:-no-response}"; fi

code=$(pod exec -i "$CONTAINER" bash -c 'curl -sk -m 15 -o /dev/null -w "%{http_code}" https://127.0.0.1/' 2>/dev/null)
if [ "$code" = 200 ]; then ok "nginx https :443" "$code"; else bad "nginx https :443" "${code:-no-response}"; fi

code=$(pod exec -i "$CONTAINER" bash -c 'curl -sk -m 15 -o /dev/null -w "%{http_code}" https://127.0.0.1/login' 2>/dev/null)
if [ "$code" = 200 ]; then ok "web ui /login" "$code"; else bad "web ui /login" "${code:-no-response}"; fi

echo "== external =="
ext=$(pod inspect "$CONTAINER" --format '{{range $p, $b := .HostConfig.PortBindings}}{{range $b}}{{.HostPort}} {{end}}{{end}}' 2>/dev/null | tr ' ' '\n' | grep -E '^11443$' || true)
info "container 443 -> host" "${ext:-?}"
if [ -n "$ext" ]; then ok "host port 11443" "published"; else bad "host port 11443" "not published"; fi

echo
if [ "$FAIL" -eq 0 ]; then
    echo "RESULT: PASS ($PASS checks)"
    exit 0
else
    echo "RESULT: FAIL ($FAIL failed, $PASS passed)"
    echo "See docs/DIAGNOSIS.md, then: sudo ./scripts/bootstrap.sh --repair"
    exit 1
fi
