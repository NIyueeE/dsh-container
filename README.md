# dsh Container Image

Containerized [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) (`dsh`), built on
a small `debian:13-slim` base with only the toolchains this project needs: Node.js LTS, pnpm, uv,
Rust/cargo, Caddy, podman, and GitHub CLI. It is ready to use out of the box with **optional dsh
auto-update** baked in. The image is published to GitHub Container Registry; both the `compose.yaml`
and the Quadlet `.container` examples pull the image directly — no local build needed.

dsh itself comes from the official repository
[deepseek-ai/deepseek-harness](https://github.com/deepseek-ai/deepseek-harness) and is installed the
way the official README describes: install Node.js, then npm-install `@deepseek-ai/dsh`.

## Features

| Component | Description |
|---|---|
| Base image | `debian:13-slim` (small, overridable via the `BASE_IMAGE` build arg) |
| Built-in toolchain | Node.js 22 LTS, pnpm, uv, Rust/cargo, git, build-essential, Caddy, podman, gh |
| Added user-level tools | Rust/cargo (`~/.rustup` + `~/.cargo`), uv (`~/.local/bin`), pnpm (`~/.local/share/pnpm`) — persisted with `/home/dsh` |
| Container dev tool | podman (apt), with rootless subuid/subgid mapping configured; nested rootless operation depends on the host runtime |
| dsh | Global npm install of `@deepseek-ai/dsh`, same source as the official README's `npx @deepseek-ai/dsh web`; pinnable via `DSH_VERSION` |
| Auto-update | Off by default (`DSH_AUTO_UPDATE=0`); opt in with `DSH_AUTO_UPDATE=1` to update dsh to the latest npm release on container start (only upgrades, never downgrades a pinned version). The image itself supports `Pull=newer` / `AutoUpdate=registry` |
| dsh web supervisor | `dsh web` runs under a small supervisor (`dsh-web`) that restarts it automatically if it exits; run `dsh-restart` inside the container to restart dsh web without restarting the container |
| Exposure | Caddy reverse proxy (`0.0.0.0:3081` → dsh's `127.0.0.1:3080`) rewriting `Host`/`Origin` to loopback, gzip-compressing UI assets (≈1.3 MB → ≈360 KB), with optional basic auth (`DSH_PROXY_USER` / `DSH_PROXY_PASSWORD`) |
| Remote settings compatibility | Idempotent client-side patch applied before every `dsh web` start: remote browsers through the proxy can use settings/credentials, and a `crypto.randomUUID` polyfill keeps the UI working over plain-HTTP LAN access |
| Observability | OCI labels (`org.opencontainers.image.*`, incl. git revision), `HEALTHCHECK` (curl 3080 + 3081) |
| Runtime user | uid 1000 (`dsh`); `/home/dsh` is the persisted user layer and `dsh` has passwordless sudo |

The base image is pinned by default; the dsh top-level version and Rust toolchain can be pinned
with `--build-arg`. uv/pnpm are installed as user-level tools, and Caddy/podman/gh come from apt —
see [build.md](docs/build.md).

## Environment variables

| Variable | Default | Description |
|---|---|---|
| `DSH_PROXY_USER` / `DSH_PROXY_PASSWORD` | *(empty)* | Enable basic auth on the exposed proxy (recommended): without it, anyone who can reach port `3081` can drive the agent **and** read/write all settings & credentials (see [security.md](docs/security.md) "Security boundary"). Set both or neither — the entrypoint refuses to start if only one is set |
| `DSH_AUTO_UPDATE` | `0` | Set to `1` to update dsh to the latest npm release on container start; keeps the in-image version when offline or on failure |

Everything else uses built-in defaults:

- dsh data: `~/.dsh` (`/home/dsh/.dsh`) — upstream default, no `DSH_HOME` override
- working directory: `$HOME` (`/home/dsh`); dsh creates folders under it as needed
- Rust/cargo: `~/.rustup` + `~/.cargo`
- uv: `~/.local/bin` (managed Python/tool data in `~/.local/share/uv`)
- pnpm: `~/.local/share/pnpm`

The whole `/home/dsh` directory is the persistence boundary: mount it as one volume so user-level
state survives while `/usr/local` and the rest of the system layer are reset on image upgrades.
User-level tools (Rust/uv/pnpm/dsh) are baked into the image and copied into a fresh named volume on
first start; system packages installed later with `sudo apt` live in the container/system layer and
are not part of the persistent home volume.

The exposed port is `3081`: a **Caddy reverse proxy** inside the container listens on
`0.0.0.0:3081` and forwards to `dsh web` on `127.0.0.1:3080`, rewriting `Host`/`Origin` to loopback.
UI assets are gzip-compressed by the proxy (≈1.3 MB → ≈360 KB), which matters most for remote
access; SSE/WebSocket streams pass through unbuffered (verified against Caddy 2.6), so agent
output is not delayed by the proxy. For WAN access, terminate TLS with an external reverse proxy in
front of `3081`; it must forward the WebSocket upgrade headers (`proxy_set_header Upgrade
$http_upgrade` / `proxy_set_header Connection "upgrade"` with nginx) and must not buffer or time
out quiet streams — see [deployment.md](docs/deployment.md) for a working example. dsh's `/api`
browser-trust fence checks HTTP headers only, so remote browsers pass every endpoint —
including settings/credentials methods that are otherwise loopback-only. **The proxy is therefore
the security boundary**: anyone who can reach `3081` gets full control, so enable
`DSH_PROXY_USER`/`DSH_PROXY_PASSWORD` and keep the port firewalled. Upstream dsh's browser code
still gates the settings/credentials pages on `window.location.hostname`, so this image also
applies a small idempotent client-side patch before every `dsh web` start: it treats proxied
remote browsers as loopback and injects a `crypto.randomUUID` polyfill for plain-HTTP LAN use. If
an upstream dsh version changes the bundle strings the patch warns and skips instead of blocking
startup. Extra `dsh web` arguments can be passed through the container `command`, e.g.
`["--port", "8080"]` (changes only dsh's internal port; the exposed port stays `3081`).

Inside the container, `dsh web` is supervised by `dsh-web`: if it exits or crashes it is restarted
automatically. To restart it manually without restarting the container, run:

```sh
docker exec dsh dsh-restart
```

## Quick start

### Docker Compose (Linux)

```bash
docker compose -f examples/compose.yaml up -d
# open http://127.0.0.1:3081
```

### Podman Quadlet (Linux, recommended)

```bash
sudo mkdir -p /etc/containers/systemd
sudo cp examples/dsh.container /etc/containers/systemd/
sudo systemctl daemon-reload
sudo systemctl enable --now dsh.service
```

> **Persistence** — both examples mount one volume at `/home/dsh`. This is the user layer:
> `~/.dsh`, `~/.cargo`, npm/cache/config files, dsh-created working folders, and user-installed
> tools survive image upgrades; the system layer (`/usr/local`, apt packages) comes from the new image.

> **Networking** — `dsh web` listens on `127.0.0.1` (npm releases reject `--host 0.0.0.0`); the
> entrypoint runs a Caddy reverse proxy on `0.0.0.0:3081` that rewrites `Host`/`Origin` to loopback
> (→ dsh's `127.0.0.1:3080`), so the examples can use plain bridge networking with port `3081`
> published. See [security.md](docs/security.md) and the
> [deployment guide](docs/deployment.md) for details.

## Documentation

| Document | Contents |
|---|---|
| [docs/deployment.md](docs/deployment.md) | Deployment & maintenance: prerequisites, Compose, Quadlet, auto-update, remote access, offline use, FAQ |
| [docs/security.md](docs/security.md) | Security notes: network exposure tradeoff, credentials, trusted workloads |
| [docs/build.md](docs/build.md) | Build configuration: build args, version pinning, reproducible builds |
| [docs/releasing.md](docs/releasing.md) | Image tags, release workflow (GitHub Releases + version alignment), image cleanup |
| [docs/design.md](docs/design.md) | Design references and related projects |
| [docs/development.md](docs/development.md) | Directory structure and local development |

## License

[MIT](LICENSE)
