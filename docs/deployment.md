# Deployment & Maintenance

This guide targets running the dsh container on your own host (Docker or Podman, Linux preferred;
the Compose example also works on Docker Desktop for macOS/Windows).

## 1. Prerequisites

- Linux host (Docker Engine ≥ 24 or Podman ≥ 4.4) — or Docker Desktop for the Compose example
- Access to `ghcr.io`
- Port `3081` free (the exposed port; dsh itself listens on `127.0.0.1:3080` inside the container)
- In-container rootless podman needs a host runtime that allows nested user namespaces (Docker's
  default seccomp profile may block it); see [security.md](security.md)

## 2. Docker Compose deployment

```bash
docker compose -f examples/compose.yaml up -d
docker compose logs dsh | grep 'dsh web:'
```

`dsh web` prints a login URL with a one-time `?token=...` query. Open it through the published
proxy port once — for a local deployment that means replacing dsh's internal loopback port with
`3081`, e.g. `http://127.0.0.1:3081/?token=<token>`. The token is exchanged for a browser session
cookie and redirects to `/`. On first use, follow the Web UI wizard to configure a model (API key)
and pick a working directory under `/home/dsh` (dsh creates folders there as needed).

Images are published by `dsh-v*` release tags that match upstream dsh tags; `:latest` points to
the most recent release.

- `compose.yaml` publishes port `3081` on the host (`ports: ["3081:3081"]`, plain bridge networking).
  Inside the container, a **Caddy reverse proxy** listens on `0.0.0.0:3081`, rewrites `Host`/`Origin`
  to loopback, and forwards to dsh on `127.0.0.1:3080` — so remote browsers pass every endpoint,
  including settings/credentials (see [security.md](security.md) — the proxy is the security
  boundary; enable `DSH_PROXY_USER`/`DSH_PROXY_PASSWORD`; the image also applies an idempotent
  client-side patch so the settings pages work in remote browsers):
  - host-only publishing: change the mapping to `"127.0.0.1:3081:3081"`;
  - container-only (not reachable from the host): just don't publish the port.
- Data persistence: the `dsh-home` volume is mounted on the **whole `/home/dsh` directory**.
  This is the immutable-image user layer: `~/.dsh` (profiles / sessions / plugins / credentials),
  `~/.cargo`, pnpm store/cache, dotfiles, and any folders dsh creates under `$HOME` survive image
  upgrades, while the system layer (`/usr/local`, `/opt`, apt packages) comes from the new image.
  The dsh source tree and built artifacts live in `/opt/deepseek-harness`, so an empty or fresh
  `/home/dsh` volume never hides dsh. To access user files directly from the host, switch the
  volume to a bind mount at `/home/dsh` and keep it owned by uid 1000; on SELinux hosts keep `:Z`
  in that bind-mount definition. An empty bind mount hides the image-baked user-level tools
  (`~/.rustup`, `~/.cargo`, `~/.local`, pnpm), so prefer the named volume on first start, or copy
  `/home/dsh` out of the image into the host directory first.

## 3. Podman Quadlet deployment (recommended)

```bash
sudo mkdir -p /etc/containers/systemd
sudo cp examples/dsh.container /etc/containers/systemd/
sudo systemctl daemon-reload
sudo systemctl enable --now dsh.service

systemctl status dsh.service
journalctl -u dsh.service -f | grep 'dsh web:'
```

Open the printed `?token=...` login URL through the published port once
(`http://127.0.0.1:3081/?token=<token>` for the default `PublishPort=3081:3081`).

- `dsh.container` publishes port `3081` via `PublishPort=3081:3081` (default bridge network);
  access `http://127.0.0.1:3081`. For host-only publishing use `PublishPort=127.0.0.1:3081:3081`.
- The `dsh-home` volume is mounted on the whole `/home/dsh` directory (same persistence
  model as Compose). If you prefer host-visible storage, replace it with a bind mount at
  `/home/dsh` owned by uid 1000.
- For user-level (rootless podman) deployment, put the file in `~/.config/containers/systemd/`
  and change `WantedBy` in `[Install]` to `default.target`.

## 4. Updating dsh and the image

dsh is built into the image at `/opt/deepseek-harness` and there is no runtime npm auto-update.
To run a different dsh version, publish/use an image built from that upstream tag:

**Upgrading from v0.2.x images:** those images npm-installed dsh into the persisted volume
(`~/.local`), and that stale copy would shadow the image-provided dsh. The entrypoint handles
this automatically: on first boot with the new image it removes the legacy
`~/.local/lib/node_modules/@deepseek-ai/dsh` tree and `~/.local/bin/dsh` entry from the volume
(idempotently; unrelated npm packages are kept), and PATH is image-first. After upgrading and
restarting the container, verify with `docker exec dsh dsh --version` (or `podman exec dsh dsh
--version`) — it must print the version matching the image tag. To clean an image's provenance
stamp: `docker exec dsh cat /etc/dsh-container/provenance.json`.

- **Quadlet** already sets `Pull=newer` (pulls on restart when a newer remote image exists) and
  `AutoUpdate=registry`; combine with `systemctl enable --now podman-auto-update.timer` to
  periodically pull new images and restart the container.
- **Compose**: `docker compose pull && docker compose up -d` achieves the same manually.

### 4.1 Restart dsh web without restarting the container

`dsh web` runs under a small supervisor (`dsh-web`) that restarts it automatically if it exits. To
force a restart from inside the running container:

```sh
docker exec dsh dsh-restart
# or: podman exec dsh dsh-restart
```

This sends `SIGTERM` to the current `dsh web` process; the supervisor starts it again with the same
container command arguments. Use it after manually changing dsh config/files that need a reload,
without bouncing Caddy or the whole container.

## 5. Remote access

With bridge networking the service is LAN-reachable by default (port `3081` published; a Caddy
reverse proxy on `0.0.0.0:3081` rewrites `Host`/`Origin` to loopback and exposes the UI — see
[security.md](security.md)). Treat it like any network service:

- keep port `3081` closed in the host firewall unless LAN access is actually needed;
- **enable the proxy's basic auth** (`DSH_PROXY_USER` / `DSH_PROXY_PASSWORD`) for any non-loopback
  deployment — the header rewrite means anyone reaching `3081` can read/write settings and
  credentials;
- for anything beyond the LAN, use an authenticated reverse proxy on the host (e.g. Caddy + basic
  auth) or an SSH tunnel:

```bash
ssh -L 3081:127.0.0.1:3081 user@your-host
# open http://127.0.0.1:3081 in your local browser
```

The proxy's header rewrite makes every request look loopback, so there is no trust configuration
to set for remote access — basic auth (`DSH_PROXY_USER` / `DSH_PROXY_PASSWORD`) and the browser
session token are the access controls. The token is printed once per `dsh web` process launch to
the container logs; anyone who can read the logs and reach port `3081` can establish a browser
session.

Upstream dsh's browser code still gates the settings/credentials pages on
`window.location.hostname`, so the Caddy rewrite alone would not make those pages usable in a
remote browser. This image runs `dsh-client-patch` before every `dsh web` start: it treats proxied
remote browsers as loopback and injects a `crypto.randomUUID` polyfill for plain-HTTP LAN use. The
patch is idempotent and best-effort — if an upstream dsh version changes the bundle strings, it
warns and skips instead of blocking startup.

### External reverse proxy with TLS (WAN)

`3081` is plain HTTP, so for anything beyond the LAN, terminate TLS in front of the container with
an authenticated reverse proxy (nginx, Caddy, Traefik, ...). The proxy config matters — two common
mistakes silently break the Web UI's event streams while the page itself still loads:

- **Missing WebSocket upgrade headers.** The UI streams agent events over WebSocket
  (`/api/events.mux`, `/api/events.host`). dsh answers handshakes without `Upgrade`/`Connection`
  with `426 Upgrade Required`, and proxies that strip these hop-by-hop headers (nginx's default)
  kill the streams: agent output never updates, and the container journal fills with periodic
  `aborting with incomplete response ... context canceled` errors.
- **Buffering + short idle timeouts.** Streams that sit idle (agent thinking, no output) longer
  than the proxy's read timeout get cut — with nginx's default `proxy_read_timeout 60s` that shows
  up as an error roughly every minute. Disable response buffering and raise the timeouts.

A minimal nginx example that works:

```nginx
location / {
    proxy_pass http://127.0.0.1:3081;       # container's exposed port
    proxy_http_version 1.1;                 # WebSocket requires HTTP/1.1
    proxy_set_header Upgrade $http_upgrade; # required for the UI's WebSocket streams
    proxy_set_header Connection "upgrade";  # required for the UI's WebSocket streams
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_buffering off;                    # stream agent output without buffering
    proxy_read_timeout 3600s;               # don't cut quiet (idle) streams
    proxy_send_timeout 3600s;
}
```

Caddy and Traefik forward WebSocket upgrades and stream responses by default; with those you only
need the raised idle timeouts (Caddy's defaults are already unlimited).

## 6. Offline use

The running image does not contact the npm registry, and there is no boot-time dsh update to
disable. Build the image once from the desired upstream tag (pin `DSH_TAG`), then run it on hosts
that only need access to `ghcr.io` for image pulls:

```bash
podman build --format docker \
             --build-arg DSH_TAG=dsh-v0.1.2-alpha.3 \
             -t dsh-container .
```

## 7. FAQ

**Permission errors when writing to `/home/dsh`**
If you replace the named `dsh-home` volume with a host bind mount at `/home/dsh`, that host
directory must be owned by uid 1000: `sudo chown -R 1000:1000 <host-home-dir>`. The default named
volume handles ownership automatically.

**Port 3081 already in use**
The exposed port is `3081` (Caddy proxy → dsh's `127.0.0.1:3080` inside the container). Change
the host-side mapping instead: compose `ports: ["4081:3081"]`, quadlet `PublishPort=4081:3081`,
then use the new port. To move dsh's internal port, pass `command: ["--port", "8080"]` /
`Exec=--port 8080` — the proxy follows automatically. The entrypoint rejects `--port 3081`
(proxy conflict) and `--port 0` (the proxy needs a fixed internal port).

**Container exits with "DSH_PROXY_USER and DSH_PROXY_PASSWORD must be set together"**
Basic auth is enabled only when both variables are set. The entrypoint refuses to start when just
one is present, instead of silently leaving the proxy unauthenticated. Set both or remove both.

**Browser shows "dsh web authentication required" or the page redirects to a 401**
dsh web mints a fresh login token each time it starts and prints the URL to the container logs.
Get it with `docker compose logs dsh | grep 'dsh web:'` (or `journalctl -u dsh.service | grep
'dsh web:'` for Quadlet), then open the printed URL through the published port `3081` once. After
that the browser holds the session cookie and plain `http://host:3081/` works until the cookie
expires or the `/home/dsh` volume is recreated.

**How do I update dsh inside a running container?**
dsh is built into the image and immutable at runtime. Pull/run the image that is tagged with the
desired upstream dsh tag (`dsh-v*`), then recreate the container. `dsh-restart` only restarts the
current dsh web process; it does not change the dsh version.

**Remote access fails with `transport failure for /api/...: HTTP 403`**
That was the `/api` browser-trust fence rejecting non-loopback `Host` headers (settings/credentials
methods are additionally hard-pinned to loopback by upstream dsh). The in-container Caddy proxy
(which rewrites `Host`/`Origin` to loopback) fixes this: remote browsers pass every endpoint. If
you still see 403, verify you are running an image that contains the Caddy proxy and that the
browser reaches the published port `3081`. If the settings page instead shows `settings are
unavailable in this browser`, verify the image also contains the `dsh-client-patch` client-side
compatibility patch (and that `dsh web` was restarted after an update).

**Podman rootless + bind mounts**
If you bind-mount a host directory at `/home/dsh`, make sure it is owned by your uid and
readable by the container; keep the `:Z` label with SELinux.

**Remote access feels slow**
The proxy itself does not buffer: SSE responses are flushed immediately and WebSocket streams pass
through unchanged (verified against Caddy 2.6). The dominant remote-side factor is transfer size —
UI assets are ~1.3 MB uncompressed, and the in-container proxy gzip-compresses them (≈360 KB).
Remaining factors are inherent to the setup: `3081` is plain HTTP (no HTTP/2 multiplexing), every
request costs one TCP round trip, and with basic auth enabled each request also pays one bcrypt
check (~50–100 ms). For anything beyond the LAN, put an authenticated TLS reverse proxy in front.
If agent output stops updating in the UI while `DSH_PROXY_USER`/`DSH_PROXY_PASSWORD` is enabled,
the browser may not be attaching the basic-auth credentials to the WebSocket handshake (UA
behavior); verify with a WebSocket client that sends `Authorization`, or terminate authentication
at an outer proxy instead.
