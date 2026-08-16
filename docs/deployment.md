# Deployment & Maintenance

This guide targets running the dsh container on your own host (Docker or Podman, Linux preferred;
the Compose example also works on Docker Desktop for macOS/Windows).

## 1. Prerequisites

- Linux host (Docker Engine ≥ 24 or Podman ≥ 4.4) — or Docker Desktop for the Compose example
- Access to `ghcr.io`; `registry.npmjs.org` is only needed if you set `DSH_AUTO_UPDATE=1`
- Port `3081` free (the exposed port; dsh itself listens on `127.0.0.1:3080` inside the container)
- In-container rootless podman needs a host runtime that allows nested user namespaces (Docker's
  default seccomp profile may block it); see [security.md](security.md)

## 2. Docker Compose deployment

```bash
docker compose -f examples/compose.yaml up -d
docker compose -f examples/compose.yaml logs -f
```

Open `http://127.0.0.1:3081`. On first use, follow the Web UI wizard to configure a model (API key)
and pick a working directory under `/home/codespace` (dsh creates folders there as needed).

Images are published by `v*` release tags; `:latest` points to the most recent release.

- `compose.yaml` publishes port `3081` on the host (`ports: ["3081:3081"]`, plain bridge networking).
  Inside the container, a **Caddy reverse proxy** listens on `0.0.0.0:3081`, rewrites `Host`/`Origin`
  to loopback, and forwards to dsh on `127.0.0.1:3080` — so remote browsers pass every endpoint,
  including settings/credentials (see [security.md](security.md) — the proxy is the security
  boundary; enable `DSH_PROXY_USER`/`DSH_PROXY_PASSWORD`):
  - host-only publishing: change the mapping to `"127.0.0.1:3081:3081"`;
  - container-only (not reachable from the host): just don't publish the port.
- Data persistence: the `dsh-home` volume is mounted on the **whole `/home/codespace` directory**.
  This is the immutable-image user layer: `~/.dsh` (profiles / sessions / plugins / credentials),
  `~/.cargo`, npm cache, dotfiles, and any folders dsh creates under `$HOME` survive image
  upgrades, while the system layer (`/usr/local`, apt packages) comes from the new image. To
  access those files directly from the host, switch the volume to a bind mount at `/home/codespace`
  and keep it owned by uid 1000; on SELinux hosts keep `:Z` in that bind-mount definition. An
  empty bind mount hides the image-baked user-level tools (`~/.rustup`, `~/.cargo`, `~/.local`,
  pnpm), so prefer the named volume on first start, or copy `/home/codespace` out of the image
  into the host directory first.

## 3. Podman Quadlet deployment (recommended)

```bash
sudo mkdir -p /etc/containers/systemd
sudo cp examples/dsh.container /etc/containers/systemd/
sudo systemctl daemon-reload
sudo systemctl enable --now dsh.service

systemctl status dsh.service
journalctl -u dsh.service -f
```

- `dsh.container` publishes port `3081` via `PublishPort=3081:3081` (default bridge network);
  access `http://127.0.0.1:3081`. For host-only publishing use `PublishPort=127.0.0.1:3081:3081`.
- The `dsh-home` volume is mounted on the whole `/home/codespace` directory (same persistence
  model as Compose). If you prefer host-visible storage, replace it with a bind mount at
  `/home/codespace` owned by uid 1000.
- For user-level (rootless podman) deployment, put the file in `~/.config/containers/systemd/`
  and change `WantedBy` in `[Install]` to `default.target`.

## 4. Auto-update mechanisms

Two layers that don't conflict:

1. **dsh itself (inside the container)** — opt-in, off by default (`DSH_AUTO_UPDATE=0`).
   When you set `DSH_AUTO_UPDATE=1`, `entrypoint.sh` calls `dsh-update` on start:
   - compares `dsh --version` with `npm view @deepseek-ai/dsh version` (semver: only upgrades —
     never downgrades a version pinned at build time);
   - when the npm latest is newer, runs `npm install -g` (the in-image npm global directory is
     owned by uid 1000, so no root needed);
   - when offline or on failure it prints a warning and keeps the in-image version — availability
     is not affected.
   - Manual update: `docker exec dsh dsh-update` (or `podman exec dsh dsh-update`) updates the
     npm package on disk; then run `docker exec dsh dsh-restart` (or `podman exec dsh
     dsh-restart`) so the running `dsh web` process loads it without restarting the container.
     `systemctl restart dsh` also works for a Quadlet deployment (and runs boot auto-update if it
     is enabled).

2. **The image itself (orchestration layer)** —
   - Quadlet already sets `Pull=newer` (pulls on restart when a newer remote image exists) and
     `AutoUpdate=registry`; combine with `systemctl enable --now podman-auto-update.timer` to
     periodically pull new images and restart the container.
   - Compose: `docker compose pull && docker compose up -d` achieves the same manually.

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
to set for remote access — basic auth (`DSH_PROXY_USER` / `DSH_PROXY_PASSWORD`) is the access
control.

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

- Auto-update is already off by default (`DSH_AUTO_UPDATE=0`), so no runtime setting is needed.
- Pin the dsh version at image build time with `--build-arg DSH_VERSION=x.y.z`; updates then go
  through the image release process (see [releasing.md](releasing.md)).

## 7. FAQ

**Permission errors when writing to `/home/codespace`**
If you replace the named `dsh-home` volume with a host bind mount at `/home/codespace`, that host
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

**`npm registry unreachable` in the startup logs**
This only happens when `DSH_AUTO_UPDATE=1`. The container couldn't reach the npm registry and
kept the in-image dsh version; restart after network is restored, or leave auto-update off.

**Remote access fails with `transport failure for /api/...: HTTP 403`**
That was the `/api` browser-trust fence rejecting non-loopback `Host` headers (settings/credentials
methods are additionally hard-pinned to loopback by upstream dsh). The in-container Caddy proxy
(which rewrites `Host`/`Origin` to loopback) fixes this: remote browsers pass every endpoint. If
you still see 403, verify you are running an image that contains the Caddy proxy and that the
browser reaches the published port `3081`.

**Podman rootless + bind mounts**
If you bind-mount a host directory at `/home/codespace`, make sure it is owned by your uid and
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
