# install/

| File                        | Purpose                                        |
| --------------------------- | ---------------------------------------------- |
| `uosserver.service`         | host supervisor unit (`uosserver-service`)     |
| `uosserver-updater.service` | creates/re-creates the container, runs as root |
| `uosserver-repair.service`  | re-applies tuning after every recreate         |
| `server.conf.tpl`           | template for `/var/lib/uosserver/server.conf`  |
| `portmap.json`              | container port map (as shipped)                |
| `mounts.json`               | persistent bind mounts (as shipped)            |

## Port mapping

`portmap.json` does **not** contain the web UI. The updater adds it itself:

```
container 443/tcp  -> host 0.0.0.0:11443     <- the web UI
container 8080/tcp -> host 0.0.0.0:8080
container 8444/tcp -> host 0.0.0.0:8444
container 11084/tcp -> host 127.0.0.1:11084
```

That is why the UI lives on **11443**, not 443. Verified against a working
install with `podman port uosserver`.

## Payload tarball

The vendor binaries are not in this repo. Build the payload from a working box:

```bash
sudo tar czf uosserver-payload-v5.1.42.tar.gz \
    var/lib/uosserver/bin \
    var/lib/uosserver/portmap.json \
    var/lib/uosserver/mounts.json \
    etc/systemd/system/uosserver.service \
    etc/systemd/system/uosserver-updater.service
```

It extracts to `/` (`tar xzf ... -C /`) and is ~13 MB.

## Image tarball

```bash
podman save docker.io/library/uosserver:c9603dec9010 | gzip > uosserver-image.tar.gz
```

~1.9 GB compressed. Necessary for a genuinely fresh VPS; skip it if the image
is already present.
