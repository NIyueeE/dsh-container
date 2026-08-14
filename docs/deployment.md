# Deployment & Maintenance

This guide targets running the dsh container on your own host (Docker or Podman, Linux preferred;
the Compose example also works on Docker Desktop for macOS/Windows).

## 1. Prerequisites

- Linux host (Docker Engine ≥ 24 or Podman ≥ 4.4) — or Docker Desktop for the Compose example
- Access to `ghcr.io` and `registry.npmjs.org` (the dsh auto-update on container start needs the npm
  registry; offline environments: see "Offline use" below)
- Port `3080` free

## 2. Docker Compose deployment

```bash
# Workspace directory: the in-container user is uid 1000, so align host ownership
mkdir -p workspace
sudo chown -R 1000:1000 workspace

docker compose -f examples/compose.yaml up -d
docker compose -f examples/compose.yaml logs -f
```

Open `http://127.0.0.1:3080`. On first use, follow the Web UI wizard to configure a model (API key)
and pick a workspace.

- `compose.yaml` publishes port `3080` on the host (`ports: ["3080:3080"]`, plain bridge networking).
  Inside the container, dsh listens on `0.0.0.0` (`DSH_WEB_HOST`, see
  [security.md](security.md) for the exposure tradeoff):
  - host-only publishing: change the mapping to `"127.0.0.1:3080:3080"`;
  - loopback-only inside the container: set `DSH_WEB_HOST=127.0.0.1` — port mapping then no longer
    works (use host networking or a tunnel/forwarder instead).
- Data persistence: the `dsh-home` named volume holds `$DSH_HOME` (profiles / sessions / plugins);
  `./workspace` is bind-mounted to `/workspace` as the task workspace.
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

- `dsh.container` publishes port `3080` via `PublishPort=3080:3080` (default bridge network);
  access `http://127.0.0.1:3080`. For host-only publishing use `PublishPort=127.0.0.1:3080:3080`.
- After changing the workspace path, re-run `daemon-reload` + `restart`.
- For user-level (rootless podman) deployment, put the file in `~/.config/containers/systemd/`
  and change `WantedBy` in `[Install]` to `default.target`.

## 4. Auto-update mechanisms

Two layers that don't conflict:

1. **dsh itself (inside the container)** — on container start `entrypoint.sh` calls `dsh-update`:
   - compares `dsh --version` with `npm view @deepseek-ai/dsh version`;
   - on mismatch runs `npm install -g` (the in-image npm global directory is owned by uid 1000,
     so no root needed);
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

With bridge networking the service is LAN-reachable by default (port `3080` published; dsh binds
`0.0.0.0` inside the container — see [security.md](security.md)). Treat it like any network service:

- keep port `3080` closed in the host firewall unless LAN access is actually needed;
- for anything beyond the LAN, use an authenticated reverse proxy on the host (e.g. Caddy + basic
  auth) or an SSH tunnel:

```bash
ssh -L 3080:127.0.0.1:3080 user@your-host
# open http://127.0.0.1:3080 in your local browser
```

- when browsers access the UI from other machines, the `/api` browser-trust fence may require
  `--trusted-host <host>:3080` (compose: `command: ["--trusted-host", "host:3080"]`;
  quadlet: `Exec=--trusted-host host:3080`).

## 6. Offline use

- Pin the update behavior at build time: set `DSH_AUTO_UPDATE=0` at runtime
  (`DSH_AUTO_UPDATE: "0"` in compose, `Environment=DSH_AUTO_UPDATE=0` in quadlet).
- The dsh version is fixed by `--build-arg DSH_VERSION=x.y.z` at image build time; updates then go
  through the image release process (see [releasing.md](releasing.md)).

## 7. FAQ

**Permission errors when writing to the workspace in the container**
The host workspace directory must be owned by uid 1000: `sudo chown -R 1000:1000 workspace`.

**Port 3080 already in use**
`dsh web` supports `--port`; in compose add `command: ["--port", "8080"]`,
in quadlet add `Exec=--port 8080`, then use the new port.

**`npm registry unreachable` in the startup logs**
The container couldn't reach the npm registry and kept the in-image dsh version; restart after
network is restored.

**Podman rootless + bind mounts**
Make sure the directory is owned by your uid and readable by the container; keep the `:Z` label
with SELinux.
