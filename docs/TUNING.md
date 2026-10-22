# Tuning reference

## Knobs

| Knob                          | File                                  | 1 GB (this build) | 2 GB  | 4 GB  |
| ----------------------------- | ------------------------------------- | ----------------- | ----- | ----- |
| `UV_THREADPOOL_SIZE`          | `/etc/default/unifi-core`             | **16**            | 32    | 64    |
| node `--max-old-space-size`   | `unifi-core.service.d/exec-heap.conf` | **800**           | 1200  | 2000  |
| `MemoryMax`                   | `unifi-core.service.d/memory.conf`    | **1024M**         | 2048M | 4096M |
| `MemorySwapMax`               | same                                  | **512M**          | 512M  | 512M  |
| JVM heap                      | `/etc/default/unifi` (`-Xmx`)         | **384m**          | 768m  | 1536m |
| container `pids.max`          | host cgroup (runtime)                 | **2048**          | 2048  | 2048  |
| postgres `max_connections`    | `postgresql.conf`                     | **20**            | 40    | 100   |
| mongo `wiredTigerCacheSizeGB` | `/etc/mongod.conf`                    | **0.15**          | 0.35  | 1.0   |
| swap                          | host                                  | **2 GB**          | 2 GB  | 2 GB  |

Only `UV_THREADPOOL_SIZE`, `pids.max` and `MemoryMax` are hard requirements.
The rest are comfort.

## Why is `UV_THREADPOOL_SIZE` that important

Node's libuv threadpool default is **4**. Ubiquiti comes with **256**. Each thread
costs a pid (and an 8 MB stack, so 2 GB of address space on a 1 GB box).

`pids.max` on this container is **363**. 256 + V8 workers + main = **269**.
That leaves 94 pids for every other process in the container.

At `16` the service uses **29** pids total, which is plenty: the pool is for
fs / dns / crypto / zlib, not for request concurrency.

Do not raise this without also raising `pids.max`. Raising `pids.max` alone
works but still wastes 2 GB of address space.

## Why the node heap is 800

`--max-old-space-size=300` is the shipped value and it aborts. The bundle's
module graph needs more than 300 MB of old space during loading. 800 MB is a
_cap_, not an allocation — real RSS sits at ~250 MB. Raising it costs nothing
because V8 only commits what it touches.

## Why the JVM is `-Xmx384m`

The unit ships `-XX:MaxRAMPercentage=70.0`, which on 952 MB asks for ~666 MB of
heap. That is fatal next to mongod, postgres, rabbitmq, nginx and node.
`-Xmx` overrides `MaxRAMPercentage`, so both are present in `/etc/default/unifi`.

> **Careful:** systemd's `EnvironmentFile` parser does **not** treat `#` as a
> comment inside a quoted value. Adding `# note` to `UNIFI_JVM_OPTS="..."`
> turns it into a stray java argument and you get
> `Could not find or load main class #`. Keep comments outside the quotes.

## Where each file lives (and whether it survives)

| Path                                            | Survives container recreate?       |
| ----------------------------------------------- | ---------------------------------- |
| `/data/unifi`, `/data/unifi-core`               | **yes** — persistent podman volume |
| `/etc/default/unifi`, `/etc/default/unifi-core` | no — overlay                       |
| `/etc/systemd/system/*.d/*.conf`                | no — overlay                       |
| `/usr/share/unifi-core`                         | no — overlay                       |
| `/var/lib/uosserver/*`                          | yes — host                         |
| container cgroup `pids.max`                     | no — recreated with the container  |

Everything in the "no" column is re-applied by `uosserver-repair.service`.

## Applying a change

```bash
sudo ./scripts/bootstrap.sh --repair   # re-applies the whole tuning set
```

or by hand inside the container:

```bash
sudo -u uosserver podman exec -i uosserver bash -s <<'EOS'
sed -i 's/^UV_THREADPOOL_SIZE=.*/UV_THREADPOOL_SIZE=16/' /etc/default/unifi-core
systemctl daemon-reload
systemctl restart unifi-core
EOS
```

Then wait — `unifi-core` needs 2–6 minutes to bind 11081 on this hardware, and
the Java app another 5–10. Do not assume it failed just because nothing happens
for a few minutes.

## Verifying a change took effect

```bash
sudo ./scripts/verify.sh
```

or individually:

```bash
systemctl show unifi-core -p TasksCurrent        # expect ~29, not ~269
cat /sys/fs/cgroup/user.slice/user-$(id -u uosserver).slice/user@$(id -u uosserver).service/user.slice/libpod-*/pids.max
systemctl show unifi-core -p MemoryMax           # expect 1073741824
```

## If the box is slower than this one

This instance has very high hypervisor steal (60–85 % at times). If yours is
better, restarts will be much faster and you can raise `UV_THREADPOOL_SIZE`
toward 32 without trouble. If yours is worse, you are below the practical floor
— move to a bigger instance or a Cloud Key.
