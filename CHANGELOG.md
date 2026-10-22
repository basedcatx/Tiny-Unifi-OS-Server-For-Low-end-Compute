# Changelog

### Changes

- `UV_THREADPOOL_SIZE` 256 → **16** (269 → 29 threads)
- container `pids.max` 363 → **2048**
- node `--max-old-space-size` 300 → **800**
- `MemoryMax` 300M → **1024M** (+ `MemorySwapMax=512M`)
- JVM heap: `MaxRAMPercentage=70` (~666 MB) → **`-Xmx384m`**
- start timeouts widened, `WatchdogSec=infinity`, `KillMode=control-group`
- `/data/unifi-core/config/http/` created in the persistent volume
- MongoDB `wiredTigerCacheSizeGB` → 0.15, postgres `max_connections` → 20
- disabled: Oracle cloud-agent snap, host apache2, five Go identity apps,
  fwupd / iscsid / ModemManager / rpcbind / apt-daily timers

### Tooling

- `bootstrap.sh` — fresh-install / repair / verify
- `uosserver-repair.service` — re-applies tuning after every container recreate
