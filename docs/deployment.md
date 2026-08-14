# Deployment & Maintenance

This guide targets running the dsh container on your own host (Docker or Podman, Linux preferred;
the Compose example also works on Docker Desktop for macOS/Windows).

## 1. Prerequisites

- Linux host (Docker Engine ≥ 24 or Podman ≥ 4.4) — or Docker Desktop for the Compose example
- Access to `ghcr.io` and `registry.npmjs.org` (the dsh auto-update on container start needs the npm
  registry; offline environments: see "Offline use" below)
- Port `3081` free (the exposed port; dsh itself listens on `127.0.0.1:3080` inside the container)

## 2. Docker Compose deployment

```bash
# Workspace directory: the in-container user is uid 1000, so align host ownership
mkdir -p workspace
sudo chown -R 1000:1000 workspace

docker compose -f examples/compose.yaml up -d
docker compose -f examples/compose.yaml logs -f
```

Open `http://127.0.0.1:3081`. On first use, follow the Web UI wizard to configure a model (API key)
and pick a workspace.

Images are published only by `v*` release tags; `:latest` points to the most recent release. Before
the first release exists, replace the image tag with a published version or build locally
(see [releasing.md](releasing.md) / [build.md](build.md)).

- `compose.yaml` publishes port `3081` on the host (`ports: ["3081:3081"]`, plain bridge networking).
  Inside the container, a **Caddy reverse proxy** listens on `0.0.0.0:3081`, rewrites `Host`/`Origin`
  to loopback, and forwards to dsh on `127.0.0.1:3080` — so remote browsers pass every endpoint,
  including settings/credentials (see [security.md](security.md) — the proxy is the security
  boundary; enable `DSH_PROXY_USER`/`DSH_PROXY_PASSWORD`):
  - host-only publishing: change the mapping to `"127.0.0.1:3081:3081"`;
  - loopback-only: just don't publish the port.
- Data persistence: the `dsh-home` named volume holds `$DSH_HOME` (default `$HOME/dsh`, i.e.
  `/home/codespace/dsh` on universal 6.x — profiles / sessions / plugins); `./workspace` is
  bind-mounted to `/home/codespace/workspace` (default `$DSH_WORKSPACE`) as the task workspace.
- On SELinux hosts (Fedora etc.) keep the `:Z` label in the volume definitions.

## 3. Podman Quadlet deployment (recommended)

```bash
sudo mkdir -p /etc/containers/systemd
sudo cp examples/dsh.container /etc/containers/systemd/
# adjust /home/you/workspace in examples/dsh.container to your workspace path
sudo systemctl daemon-reload
sudo systemctl enable --now dsh.service

systemctl status dsh.service
journalctl -u dsh.service -f
```

- `dsh.container` publishes port `3081` via `PublishPort=3081:3081` (default bridge network);
  access `http://127.0.0.1:3081`. For host-only publishing use `PublishPort=127.0.0.1:3081:3081`.
- After changing the workspace path, re-run `daemon-reload` + `restart`.
- For user-level (rootless podman) deployment, put the file in `~/.config/containers/systemd/`
  and change `WantedBy` in `[Install]` to `default.target`.

## 4. Auto-update mechanisms

Two layers that don't conflict:

1. **dsh itself (inside the container)** — on container start `entrypoint.sh` calls `dsh-update`:
   - compares `dsh --version` with `npm view @deepseek-ai/dsh version` (semver: only upgrades —
     never downgrades a version pinned at build time);
   - when the npm latest is newer, runs `npm install -g` (the in-image npm global directory is
     owned by uid 1000, so no root needed);
   - when offline or on failure it prints a warning and keeps the in-image version — availability
     is not affected.
   - Manual update: `docker exec dsh dsh-update` / `systemctl restart dsh`.
   - Scheduled updates (optional): hand a `DSH_UPDATE_ONLY=1` container to a systemd timer or cron,
     e.g. run `docker run --rm -e DSH_UPDATE_ONLY=1 ... dsh-container` every hour.

2. **The image itself (orchestration layer)** —
   - Quadlet already sets `Pull=newer` (pulls on restart when a newer remote image exists) and
     `AutoUpdate=registry`; combine with `systemctl enable --now podman-auto-update.timer` to
     periodically pull new images and restart the container.
   - Compose: `docker compose pull && docker compose up -d` achieves the same manually.

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

## 6. Offline use

- Pin the update behavior at build time: set `DSH_AUTO_UPDATE=0` at runtime
  (`DSH_AUTO_UPDATE: "0"` in compose, `Environment=DSH_AUTO_UPDATE=0` in quadlet).
- The dsh version is fixed by `--build-arg DSH_VERSION=x.y.z` at image build time; updates then go
  through the image release process (see [releasing.md](releasing.md)).

## 7. FAQ

**Permission errors when writing to the workspace in the container**
The host workspace directory (bind-mounted to `/home/codespace/workspace`, default `$DSH_WORKSPACE`)
must be owned by uid 1000: `sudo chown -R 1000:1000 workspace`.

**Port 3081 already in use**
The exposed port is `3081` (Caddy proxy → dsh's `127.0.0.1:3080` inside the container). Change
the host-side mapping instead: compose `ports: ["4081:3081"]`, quadlet `PublishPort=4081:3081`,
then use the new port. To move dsh's internal port, pass `command: ["--port", "8080"]` /
`Exec=--port 8080` — the proxy follows automatically, but keep it different from `3081`.

**`npm registry unreachable` in the startup logs**
The container couldn't reach the npm registry and kept the in-image dsh version; restart after
network is restored.

**Remote access fails with `transport failure for /api/...: HTTP 403`**
That was the `/api` browser-trust fence rejecting non-loopback `Host` headers (settings/credentials
methods are additionally hard-pinned to loopback by upstream dsh). The in-container Caddy proxy
(which rewrites `Host`/`Origin` to loopback) fixes this: remote browsers pass every endpoint. If
you still see 403, verify you are running an image that contains the Caddy proxy and that the
browser reaches the published port `3081`.

**Podman rootless + bind mounts**
Make sure the directory is owned by your uid and readable by the container; keep the `:Z` label
with SELinux.

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
