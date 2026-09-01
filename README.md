# dsh Container Image

Containerized [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) (`dsh`), built on
a small `debian:13-slim` base with only the toolchains this project needs: Node.js LTS, pnpm, uv,
Rust/cargo, Caddy, podman, and GitHub CLI. The image is published to GitHub Container Registry;
both the `compose.yaml` and the Quadlet `.container` examples pull the image directly — no local
build needed.

dsh itself is built from the official repository
[deepseek-ai/deepseek-harness](https://github.com/deepseek-ai/deepseek-harness), the same way the
official README describes: clone the repository, check out a `dsh-v*` tag, then `pnpm install` and
`pnpm run build:official`.

## Features

| Component | Description |
|---|---|
| Base image | `debian:13-slim` (small, overridable via the `BASE_IMAGE` build arg) |
| Built-in toolchain | Node.js 22 LTS, pnpm, uv, Rust/cargo, git, build-essential, Caddy, podman, gh |
| Added user-level tools | Rust/cargo (`~/.rustup` + `~/.cargo`), uv (`~/.local/bin`), pnpm (`~/.local/share/pnpm`) — persisted with `/home/dsh` |
| Container dev tool | podman (apt), with rootless subuid/subgid mapping configured; nested rootless operation depends on the host runtime |
| dsh | Built from the official source tag (`git clone` + `git checkout dsh-v*` + `pnpm install` + `pnpm run build:official`) into `/opt/deepseek-harness`; pinnable via `DSH_TAG` |
| Versioning | Image release tags match the upstream dsh tags (`dsh-v*`); `latest` points to the most recent release image |
| dsh web supervisor | `dsh web` runs under a small supervisor (`dsh-web`) that restarts it automatically if it exits; run `dsh-restart` inside the container to restart dsh web without restarting the container |
| Exposure | Caddy reverse proxy (`0.0.0.0:3081` → dsh's `127.0.0.1:3080`) rewriting `Host`/`Origin` to loopback, gzip-compressing UI assets (≈1.3 MB → ≈360 KB), with optional basic auth (`DSH_PROXY_USER` / `DSH_PROXY_PASSWORD`) |
| Remote settings compatibility | Idempotent client-side patch applied before every `dsh web` start: remote browsers through the proxy can use settings/credentials, and a `crypto.randomUUID` polyfill keeps the UI working over plain-HTTP LAN access |
| Observability | OCI labels (`org.opencontainers.image.*`, incl. git revision), `HEALTHCHECK` (curl 3080 + 3081) |
| Runtime user | uid 1000 (`dsh`); `/home/dsh` is the persisted user layer and `dsh` has passwordless sudo |

The base image is pinned by default; the dsh source tag and Rust toolchain can be pinned with
`--build-arg`. pnpm is installed at the version required by the checked-out dsh tag, and
Caddy/podman/gh come from apt — see [build.md](docs/build.md).

## Environment variables

| Variable | Default | Description |
|---|---|---|
| `DSH_PROXY_USER` / `DSH_PROXY_PASSWORD` | *(empty)* | Enable basic auth on the exposed proxy (recommended): without it, anyone who can reach port `3081` can drive the agent **and** read/write all settings & credentials (see [security.md](docs/security.md) "Security boundary"). Set both or neither — the entrypoint refuses to start if only one is set |

Everything else uses built-in defaults:

- dsh data: `~/.dsh` (`/home/dsh/.dsh`) — upstream default, no `DSH_HOME` override
- working directory: `$HOME` (`/home/dsh`); dsh creates folders under it as needed
- Rust/cargo: `~/.rustup` + `~/.cargo`
- uv: `~/.local/bin` (managed Python/tool data in `~/.local/share/uv`)
- pnpm: `~/.local/share/pnpm`

The whole `/home/dsh` directory is the persistence boundary: mount it as one volume so user-level
state survives while `/usr/local`, `/opt`, and the rest of the system layer are reset on image
upgrades. User-level tools (Rust/uv/pnpm) are baked into the image and copied into a fresh named
volume on first start; the dsh source tree and built artifacts live in the system layer at
`/opt/deepseek-harness` and are replaced with each image upgrade. System packages installed later
with `sudo apt` live in the container/system layer and are not part of the persistent home volume.

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
startup. dsh web prints a login URL with a `?token=...` query to the container logs; open that
URL through the published port `3081` once so the browser receives the session cookie. Extra `dsh web` arguments can be passed through the container `command`, e.g.
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
docker compose logs dsh | grep 'dsh web:'
# open the printed token URL through the published proxy port, e.g. http://127.0.0.1:3081/?token=<token>
```

### Podman Quadlet (Linux, recommended)

```bash
sudo mkdir -p /etc/containers/systemd
sudo cp examples/dsh.container /etc/containers/systemd/
sudo systemctl daemon-reload
sudo systemctl enable --now dsh.service
```

> **Persistence** — both examples mount one volume at `/home/dsh`. This is the user layer:
> `~/.dsh`, `~/.cargo`, pnpm store/cache/config files, dsh-created working folders, and
> user-installed tools survive image upgrades; the system layer (`/usr/local`, `/opt`, apt
> packages) comes from the new image.

> **Networking** — `dsh web` listens on `127.0.0.1` (upstream dsh rejects `--host 0.0.0.0`); the
> entrypoint runs a Caddy reverse proxy on `0.0.0.0:3081` that rewrites `Host`/`Origin` to loopback
> (→ dsh's `127.0.0.1:3080`), so the examples can use plain bridge networking with port `3081`
> published. See [security.md](docs/security.md) and the
> [deployment guide](docs/deployment.md) for details.

## Documentation

| Document | Contents |
|---|---|
| [docs/deployment.md](docs/deployment.md) | Deployment & maintenance: prerequisites, Compose, Quadlet, remote access, offline use, FAQ |
| [docs/security.md](docs/security.md) | Security notes: network exposure tradeoff, credentials, trusted workloads |
| [docs/build.md](docs/build.md) | Build configuration: build args, source tag pinning, reproducible builds |
| [docs/releasing.md](docs/releasing.md) | Image tags, release workflow (GitHub Releases + upstream tag alignment), image cleanup |
| [docs/design.md](docs/design.md) | Design references and related projects |
| [docs/development.md](docs/development.md) | Directory structure and local development |

## License

[MIT](LICENSE)
