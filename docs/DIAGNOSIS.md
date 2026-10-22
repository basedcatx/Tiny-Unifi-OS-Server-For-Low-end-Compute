# Diagnosis: why this took hours

**TL;DR — it was never V8. It was `pids.max`.**

`unifi-core` ships `UV_THREADPOOL_SIZE=256` in `/etc/default/unifi-core`. On a
small box that is 269 threads for one service. The podman container cgroup is
created with `pids.max=363`. That leaves ~94 pids for systemd, mongod, twelve
postgres backends, rabbitmq, nginx, ulp-go and the Java controller — combined.

Everything below follows from that single fact.

---

## The symptoms as they appeared

1. Container healthcheck failed: `curl: (7) Failed to connect to 127.0.0.1 port 80`
2. `unifi-core` (node24) never reached `active` — it restarted every few minutes
3. Host supervisor logged `Supervisor Timeout: Ucore did not start within 60s` forever
4. The Java controller never bound 8080/8443
5. `fork: retry: Resource temporarily unavailable` scattered through the journal

Symptom 2 was the trap. `unifi-core` did not "crash". It **aborted itself**.

---

## The misleading signal

`strace` showed a self-inflicted abort:

```
rt_sigprocmask(SIG_UNBLOCK, [ABRT], NULL, 8) = 0
rt_sigprocmask(SIG_BLOCK, ~[RTMIN RT_1], NULL, 8) = 0
tgkill(<tid>, <tid>, SIGABRT) = 0
--- SIGABRT {si_signo=SIGABRT, si_code=SI_TKILL, si_pid=<self>, si_uid=0} ---
```

`si_code=SI_TKILL`, `si_pid=self`. Not the OOM killer (that sends SIGKILL), not
systemd's watchdog (that arrives as `SI_USER` from systemd's pid), not the host
supervisor. Node killed itself.

Critically: **it printed nothing.** No `FATAL ERROR`, no
`JavaScript heap out of memory`, no `terminate called`, no `Watchdog timeout`.
Even `--report-on-signal` produced no report.

That silence is the tell. A V8 `CHECK` failure prints its message first.
`ImmediateCrash()` is a `ud2` (SIGILL). A bare `abort()` with no output means
the failure happened somewhere that could not even format a message — which, in
retrospect, is what a failed `pthread_create` looks like.

---

## Dead ends (do not repeat these)

All of these still aborted at t≈130–200 s:

| Tried | Result |
|---|---|
| `--jitless` | died t=200 s |
| `--no-sparkplug` | died t=155 s |
| `--no-maglev` | died |
| `--no-wasm-tier-up` | died t=155 s |
| `--no-node-snapshot` | died t=160 s |
| `--predictable` | died t=130 s |
| `--max-old-space-size=300 / 800 / 1200` | all died (until the pid fix landed) |
| `--disable-sandbox` | not a valid flag in node 24.8.0 → `bad option` |

Also ruled out:

- **WASM.** No `.wasm` files anywhere in the app, no base64 wasm magic
  (`AGFzbQ`) in the bundle. The gdb symbol `wasm::WasmFullDecoder` was a red
  herring — it is merely the nearest *exported* symbol in a stripped binary.
- **sharp / libvips.** Loads fine standalone.
- **`detect-libc`.** Reads only 2048 bytes of `/proc/self/exe`
  (`MAX_LENGTH = 2048`), so the `/proc/self/exe` open right before the abort
  is not a memory event.
- **Memory exhaustion.** RSS stabilised at ~250–270 MB with ~500 MB available.
  `memavail` never dropped below ~510 MB.
- **systemd watchdog.** Unit has `WatchdogSec=2min` + `WatchdogSignal=6`, but
  the signal is self-sent (`SI_TKILL`), and no watchdog line was logged.

### Why the gdb backtrace lied

```
#0 raise()  #1 abort()  #2 v8::internal::MacroAssembler::DecompressTagged
#3 __pthread_once_slow  #4 uv_once  #5 ??  #6 uv_fs_close
```

Frames `#5` onward were garbage — the unwinder lost sync (no `.eh_frame`
unwinding for a binary copied out of the container). Even `#2` is unreliable:
in a stripped `node24` the symbol is just the nearest preceding export. The
disassembly around the abort site was a wall of `ud2` + `call abort@plt`
thunks, which is what V8's `CHECK`/`UNREACHABLE` expansion looks like — not
evidence of any particular V8 subsystem.

**Lesson: a symbol name from a stripped binary is not a stack trace.**

---

## The actual cause, proven

```
$ cat /sys/fs/cgroup/.../libpod-<id>.scope/pids.max
363
$ cat /sys/fs/cgroup/.../libpod-<id>.scope/pids.current
363          # 100 % full

$ dmesg | tail
cgroup: fork rejected by pids controller in /user.slice/user-1002.slice/.../libpod-<id>.scope
```

And inside the container:

```
$ systemctl show unifi-core -p TasksCurrent
TasksCurrent=269        # UV_THREADPOOL_SIZE=256 + V8 workers + main
```

269 of 363 pids consumed by a single service. Everything else fought over the
remaining 94.

> **It comes back.** Raising `pids.max` is not permanent: podman resets the
> container cgroup to `363` on every container **start**, not just on recreate.
> That is why `uosserver-pids.timer` re-raises it every 30 seconds, and why
> "it broke again after I restarted it" is the classic follow-up symptom.

### The three ways it manifested

1. **node aborted silently.** `pthread_create` returned `EAGAIN` mid-startup;
   V8 cannot continue and calls `abort()` without a message.
2. **The Java controller never started.** Its `ExecStartPre` hook shells out to
   `sudo`, `psql`, `createuser`, `createdb`. With no pids left:
   ```
   /usr/share/unifi-core/app/hooks/pre-start: fork: retry: Resource temporarily unavailable
   sudo: unable to fork: Resource temporarily unavailable
   ```
   → `Job for unifi.service failed because the control process exited with error code`.
3. **False dependency.** Once the hook limped through, Java still failed at the
   `systemService` bean:
   ```
   Request to UniFi-Core failed ... GET "http://127.0.0.1:11081/api/system":
   Connect ... Connection refused
   ```
   Java **hard-requires** `unifi-core`. There is no standalone mode. `unifi.service`
   only `Wants=` it, so systemd will happily start Java without its dependency —
   you get a slow, expensive failure instead of a clean one.

---

## Secondary: the memory cap

`unifi-core.service` also ships `MemoryMax=300M`. The bundle needs ~250–270 MB
RSS *plus* page cache for the mmap'd 111 MB `node24` binary, so the cgroup was
reclaiming continuously. That alone is enough to make allocations fail.

Now `MemoryMax=1024M` with `MemorySwapMax=512M`.

---

## Why the tuning kept getting lost

`/data` is a persistent podman volume. Everything else — `/usr/share/unifi-core`,
`/etc/default/unifi`, `/etc/default/unifi-core`, all systemd drop-ins — lives in
the container's **overlay**, which `uosserver-updater` wipes on every recreate.

`uosserver-repair.service` exists to re-apply it. It had **never worked**:

- `podman exec` without `-i` → `bash -s` read EOF → the entire fix body was
  skipped, silently, because the script had no `set -e` and no verification
- `report_status()` had an unclosed double quote → `bash -n` fails outright

Both are fixed in `scripts/repair.sh`.

---

## Timeline of what actually mattered

| # | Discovery | Impact |
|---|---|---|
| 1 | `/data/unifi-core/config/http/` missing | cleared the stuck pre-start hook |
| 2 | node self-aborts, silently, mid-startup | narrowed to V8, wrongly blamed V8 |
| 3 | freeing CPU (mask core, stop Go apps) | GC pauses 4.9 s → 0.3 s |
| 4 | node ran fine when started outside systemd | **the tell**: systemd-only limits |
| 5 | `MemoryMax=300M` found in the unit | fixed a real constraint |
| 6 | `pids.max=363`, `TasksCurrent=269` | **root cause** |
| 7 | `UV_THREADPOOL_SIZE` 256 → 16 | 269 → 29 threads, everything came up |

Step 4 was the one that should have been tried on day one: **if a service fails
under systemd but works when run by hand, diff the systemd constraints before
touching the application.**
