#!/usr/bin/env bash
#
# pids-guard.sh - keep the container's pids.max raised.
#
# podman bootstraps the container cgroup with pids.max=363, and it RESETS to
# 363 every time the container is (re)started - not just re-created.  Since
# unifi-core wants ~30 pids after tuning (269 before), 363 is survivable but
# leaves almost nothing for java's fork-heavy pre-start hook.  Raise it and
# keep it raised.
#
# Driven by uosserver-pids.timer every 30s.  Cheap: it only reads a glob.

set -u

PIDS_MAX="${PIDS_MAX:-2048}"
uid=$(id -u uosserver 2>/dev/null) || exit 0

for f in /sys/fs/cgroup/user.slice/user-"${uid}".slice/user@"${uid}".service/user.slice/libpod-*/pids.max; do
    [ -e "$f" ] || continue
    cur=$(cat "$f" 2>/dev/null)
    [ "$cur" = "$PIDS_MAX" ] && continue
    if echo "$PIDS_MAX" > "$f" 2>/dev/null; then
        logger -t uosserver-pids -- "raised pids.max $cur -> $PIDS_MAX ($(dirname "$f"))" 2>/dev/null
    fi
done

exit 0
