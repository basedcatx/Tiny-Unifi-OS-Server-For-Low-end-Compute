# tiny-unifi-os-server

Running **UniFi OS Server v5.1.42** on a **1 GB / 2 vCPU** VPS

Read [`docs/DIAGNOSIS.md`](docs/DIAGNOSIS.md) before you debug anything.

```
CONTAINER:   uosserver  (rootless podman, pasta networking)
UI:          https://<host>:11443/        (container 443 -> host 11443)
CORE API:    http://127.0.0.1:11081/api/system
```

---

## Quick start

```bash
git clone <this repo> tiny-unifi-os-server
cd tiny-unifi-os-server

sudo ./scripts/bootstrap.sh            # install if absent, else repair+verify
sudo ./scripts/bootstrap.sh --dry-run  # print every action, change nothing
sudo ./scripts/bootstrap.sh --repair   # never install, just re-apply tuning
sudo ./scripts/bootstrap.sh --verify   # read-only health check
sudo ./scripts/bootstrap.sh --repair --no-restart   # tune without the ~10 min outage
```

`bootstrap.sh` is idempotent. Running it twice is safe.

It detects the machine state first:

| Detected                                      | Action                                    |
| --------------------------------------------- | ----------------------------------------- |
| no `/var/lib/uosserver/bin/uosserver-service` | full install (needs payload, see below)   |
| installed, container missing                  | recreate container, then repair           |
| installed, container running                  | **repair**: re-apply tuning, restart apps |
| already healthy                               | **verify** only, no restarts              |

---

## 30-second triage

| Symptom                                                                    | Look here first                                                                                                                                                                              |
| -------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Container unhealthy, `curl: (7) ... port 80`                               | Are 8080/8443 listening? `ss -tuln \| grep -E '8080\|8443'`                                                                                                                                  |
| `fork: retry: Resource temporarily unavailable`                            | **pid exhaustion.** `cat /sys/fs/cgroup/user.slice/user-$(id -u uosserver).slice/user@$(id -u uosserver).service/user.slice/libpod-*/pids.max` → must be ≥ 2048, and `UV_THREADPOOL_SIZE=16` |
| `unifi-core` restarts every ~3 min, no logs                                | Same. Check `systemctl show unifi-core -p TasksCurrent` — if ~269, the threadpool trim is missing                                                                                            |
| Java stuck at `activating (start-pre)`                                     | pid exhaustion again — the pre-start hook can't fork `sudo`/`psql`                                                                                                                           |
| Java dies with `Request to UniFi-Core failed ... 11081 Connection refused` | `unifi-core` is down. Java **cannot** start without it                                                                                                                                       |
| `Could not find or load main class #`                                      | inline `#` comment inside a quoted `EnvironmentFile` value. systemd does not strip it                                                                                                        |
| UI unreachable but nginx returns 200 locally                               | check host firewall / port 11443                                                                                                                                                             |
| Everything was fine, then container was recreated                          | `systemctl restart uosserver-repair.service`                                                                                                                                                 |
| Fine, then it broke after a plain restart                                  | `pids.max` resets to 363 on every container **start**. `uosserver-pids.timer` handles it; check `systemctl status uosserver-pids.timer`                                                      |

---

## What "small VPS" actually means

| RAM                  | Verdict                                                |
| -------------------- | ------------------------------------------------------ |
| 512 MB               | Worth the try..............                            |
| **1 GB + 2 GB swap** | **works** — this repo. Slow but functional             |
| 2 GB                 | comfortable, use the looser values in `docs/TUNING.md` |
| 4 GB                 | drop all the caps, stock-ish settings will run         |


---

## Fresh install requirements

The repo automates **everything that was learned the hard way**, but it cannot
invent the vendor payload. On a genuinely fresh VPS you need one of:

1. **`uosserver-payload-v5.1.42.tar.gz`** — the host-side binaries from a
   working box (`/var/lib/uosserver/bin`, systemd units, config templates).
   ~13 MB. Shipped alongside this repo.
2. **The container image** — `docker.io/library/uosserver:c9603dec9010`,
   **1.92 GB**. Save it from a working box:
   ```bash
   podman save docker.io/library/uosserver:c9603dec9010 | gzip > uosserver-image.tar.gz
   ```
   then load it during bootstrap with `--image-tarball uosserver-image.tar.gz`.

Without both, `bootstrap.sh` will stop after `preflight` and tell you exactly
what is missing. It will not fail halfway through.

```bash
sudo ./scripts/bootstrap.sh \
    --payload-tarball ./uosserver-payload-v5.1.42.tar.gz \
    --image-tarball   ./uosserver-image.tar.gz
```

---

## Layout

```
docs/DIAGNOSIS.md   the real root cause + every dead end (read this)
docs/TUNING.md      every knob, with values for 1/2/4 GB
scripts/bootstrap.sh      fresh VPS -> working controller, idempotent
scripts/repair.sh         re-apply tuning after a container recreate
scripts/free-resources.sh stop/mask the CPU and RAM thieves
scripts/verify.sh         ports, UI, API, health, thread counts
scripts/pids-guard.sh     keeps pids.max raised (it resets on container start)
install/                  systemd units, config templates, port map
```

## Self-healing

Two host timers keep the box healthy without intervention:

| Timer                    | Interval | Does                                                                                                      |
| ------------------------ | -------- | --------------------------------------------------------------------------------------------------------- |
| `uosserver-pids.timer`   | 30 s     | re-raises container `pids.max` to 2048 — **it resets to 363 on every container start, not just recreate** |
| `uosserver-repair.timer` | 5 min    | re-applies the threadpool trim, heap/memory caps and drop-ins if the overlay was wiped                    |

They are cheap (the pids guard only reads a glob) and log to the journal.

---

## What was disabled, and why

| Service                                                                        | Why it is off                                                                                    |
| ------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------ |
| `snap.oracle-cloud-agent`                                                      | ~68 % of a vCPU between `gomon`, `agent`, `oci-wlp`, `runcommand`. Not needed for the controller |
| `apache2` (host)                                                               | 55 idle threads; the container publishes its own nginx                                           |
| `ulp-go`, `ucs-agent`, `unifi-directory`, `uid-agent`, `unifi-identity-update` | UniFi OS identity/directory apps. Not required by the Network Application                        |
| `fwupd`, `iscsid`, `ModemManager`, `rpcbind`, `apt-daily.*`                    | unused on a cloud VM                                                                             |
| `zram`                                                                         | could not allocate on this instance                                                              |

Re-enable any of them with `systemctl unmask <unit> && systemctl enable --now <unit>`
if you need the feature back.
