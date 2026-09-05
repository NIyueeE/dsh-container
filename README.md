<div align="center">

# dsh Container Image

**[DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) (`dsh`) as a batteries-included
container — agent, full toolchain, and a reverse proxy in one image, built from the official source tags.**

[![Release](https://img.shields.io/github/v/tag/NIyueeE/dsh-container?filter=dsh-v*&label=release&sort=semver)](https://github.com/NIyueeE/dsh-container/releases)
[![CI](https://img.shields.io/github/actions/workflow/status/NIyueeE/dsh-container/image.yml?branch=main&label=CI)](https://github.com/NIyueeE/dsh-container/actions/workflows/image.yml)
[![GHCR](https://img.shields.io/badge/ghcr.io-niyueee%2Fdsh--container-2088FF?logo=docker&logoColor=white)](https://github.com/NIyueeE/dsh-container/pkgs/container/dsh-container)
[![Upstream dsh](https://img.shields.io/github/v/tag/deepseek-ai/deepseek-harness?filter=dsh-v*&label=upstream%20dsh&sort=semver)](https://github.com/deepseek-ai/deepseek-harness)
[![License](https://img.shields.io/github/license/NIyueeE/dsh-container)](LICENSE)

English | [中文](README.zh.md)

</div>

## Quick start

### Docker Compose (Linux)

```bash
docker compose -f examples/compose.yaml up -d
docker compose logs dsh | grep 'dsh web:'
# open http://127.0.0.1:3081/ in your local browser (the proxy bootstraps the login)
```

### Podman Quadlet (Linux, recommended)

```bash
sudo mkdir -p /etc/containers/systemd
sudo cp examples/dsh.container /etc/containers/systemd/
sudo systemctl daemon-reload
sudo systemctl enable --now dsh.service
```

Both examples publish `127.0.0.1:3081` and mount one volume at `/home/dsh` — the user layer
(`~/.dsh`, caches, user-installed tools) survives image upgrades while the system layer comes from
the image. There is no login step: the proxy bootstraps the dsh session automatically.

## What's inside

| Component | Description |
|---|---|
| Base image | `debian:13-slim` (pinned; overridable via the `BASE_IMAGE` build arg) |
| Toolchain | Node.js 22 LTS, pnpm, uv, Rust/cargo, git, build-essential, Caddy, podman, gh — image-owned real binaries, upgraded with the image |
| dsh | Built from the official source tag into `/opt/deepseek-harness` (`DSH_TAG` pinnable); no runtime auto-update |
| Exposure | Caddy reverse proxy (`0.0.0.0:3081` → dsh's `127.0.0.1:3080`) with optional basic auth |
| Supervisor | `dsh web` auto-restarts on exit; `docker exec dsh dsh-restart` restarts it manually |
| Remote compatibility | Idempotent client-side patch: settings/credentials work through the proxy; `crypto.randomUUID` polyfill for plain-HTTP LAN |
| Observability | OCI labels, `HEALTHCHECK` (curl 3080 + 3081) |
| Runtime user | uid 1000 (`dsh`), passwordless sudo; `/home/dsh` is the persisted user layer |

## Networking & security

- **Port model** — `dsh web` listens on `127.0.0.1:3080` (upstream rejects `--host 0.0.0.0`); the
  exposed port is `3081`, published on host loopback by the examples.
- **The proxy is the security boundary** — Caddy rewrites `Host`/`Origin` to loopback, so remote
  browsers pass dsh's `/api` trust fence, including settings/credentials methods that are otherwise
  loopback-only. Anyone who can reach `3081` gets full control: enable basic auth
  (`DSH_PROXY_USER`/`DSH_PROXY_PASSWORD`, set together or the entrypoint refuses to start) and keep
  the port firewalled.
- **Session bootstrapped** — the supervisor exchanges dsh's one-time login token at startup and
  injects the session cookie into every proxied request; browsers never see a token.
- **Streams & compression** — SSE/WebSocket pass through unbuffered (verified against Caddy 2.6);
  UI assets are gzip-compressed (≈1.3 MB → ≈360 KB).
- **Client patch** — applied before every `dsh web` start; if upstream changes the bundle strings
  it warns and skips instead of blocking startup.
- **Extra args** — pass `dsh web` arguments through the container command, e.g.
  `["--port", "8080"]` (internal port only; exposed port stays `3081`).

For WAN access, terminate TLS in front of `3081` (the docs include a working nginx config with
WebSocket headers and raised timeouts) — see [docs/deployment.md](docs/deployment.md) and
[docs/security.md](docs/security.md).

## Environment variables

| Variable | Default | Description |
|---|---|---|
| `DSH_PROXY_USER` / `DSH_PROXY_PASSWORD` | *(empty)* | Basic auth on the exposed proxy (recommended for any non-loopback deployment); set both or neither |

Everything else uses built-in defaults — dsh data at `~/.dsh`, cwd `$HOME`, writable caches under
`~/.cargo` / `~/.local/share`, image-owned tools in `/usr/local/bin` and `/opt/rust`. The whole
`/home/dsh` is the persistence boundary: mount it as one volume; image upgrades replace the
toolchain, never the data. Details in [docs/build.md](docs/build.md) and
[docs/deployment.md](docs/deployment.md).

## Documentation

| Document | Contents |
|---|---|
| [docs/deployment.md](docs/deployment.md) | Deployment & maintenance: Compose, Quadlet, remote access, offline use, FAQ |
| [docs/security.md](docs/security.md) | Security notes: network exposure tradeoff, credentials, trusted workloads |
| [docs/build.md](docs/build.md) | Build configuration: build args, source tag pinning, reproducible builds |
| [docs/releasing.md](docs/releasing.md) | Release automation: upstream tag watcher, contract check, agent repair, auto-publish |
| [docs/upstream-contract.md](docs/upstream-contract.md) | The upstream behaviors this image depends on, and how drift is detected |
| [docs/design.md](docs/design.md) | Design references and related projects |
| [docs/development.md](docs/development.md) | Directory structure and local development |

## License

[MIT](LICENSE)
