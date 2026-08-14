# dsh Container Image

Containerized [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) (`dsh`), built on
top of Microsoft's universal dev container image
[`mcr.microsoft.com/devcontainers/universal`](https://mcr.microsoft.com/en-us/artifact/mcr/devcontainers/universal/about),
ready to use out of the box with **automatic dsh updates** baked in. The image is published to
GitHub Container Registry; both the `compose.yaml` and the Quadlet `.container` examples pull the
image directly — no local build needed.

dsh itself comes from the official repository
[deepseek-ai/deepseek-harness](https://github.com/deepseek-ai/deepseek-harness) and is installed the
way the official README describes: install Node.js, then npm-install `@deepseek-ai/dsh`.

## Features

| Component | Description |
|---|---|
| Base image | `mcr.microsoft.com/devcontainers/universal:latest` (Ubuntu 24.04; large but with a complete toolchain; currently same digest as `6.1.1-noble`; pin an exact tag with the `BASE_IMAGE` build arg) |
| Built-in toolchain | Node.js 22/24 (nvm), Python, Go, Java, Docker CLI/Engine, git, build-essential, etc. |
| Added toolchain | Rust/cargo (rustup minimal profile, pinnable via `RUST_TOOLCHAIN`), uv (COPYed from the official image at a pinned version, default 0.12.3) |
| dsh | Global npm install of `@deepseek-ai/dsh`, same source as the official README's `npx @deepseek-ai/dsh web`; pinnable via `DSH_VERSION` |
| Auto-update | Updates dsh to the latest npm release on container start (can be disabled); the image itself supports `Pull=newer` / `AutoUpdate=registry` |
| Observability | OCI labels (`org.opencontainers.image.*`, incl. git revision), `HEALTHCHECK` (curl 3080) |
| Runtime user | uid 1000 (`codespace` on universal 6.x, `vscode` on legacy 2.x — handled automatically) |

All mutable components (base image / dsh / rust / uv) can be pinned with `--build-arg`; see
[build.md](docs/build.md).

## Environment variables

| Variable | Default | Description |
|---|---|---|
| `DSH_HOME` | `/dsh` | dsh data directory (profiles / sessions / plugins); mount a persistent volume |
| `DSH_AUTO_UPDATE` | `1` | Auto-update dsh to the latest npm release on boot; keeps the in-image version when offline or on failure |
| `DSH_WEB_HOST` | `0.0.0.0` | Expose dsh via an in-container socat forwarder (dsh itself listens on `127.0.0.1`; npm releases reject `--host 0.0.0.0`); `127.0.0.1` = loopback only (port mapping then won't work) |
| `DSH_UPDATE_ONLY` | `0` | Set to `1` to only run the dsh update and exit (for timer/cron updates) |

Extra `dsh web` arguments can be passed through the container `command`, e.g.
`["--port", "8080"]` (then publish that port too).

## Quick start

### Docker Compose (Linux)

```bash
mkdir -p workspace && sudo chown -R 1000:1000 workspace   # align ownership with the container user
docker compose -f examples/compose.yaml up -d
# open http://127.0.0.1:3080
```

### Podman Quadlet (Linux, recommended)

```bash
sudo mkdir -p /etc/containers/systemd
sudo cp examples/dsh.container /etc/containers/systemd/
# adjust the workspace path in examples/dsh.container as needed
sudo systemctl daemon-reload
sudo systemctl enable --now dsh.service
```

> **Networking** — `dsh web` listens on `127.0.0.1` (npm releases reject `--host 0.0.0.0`); the
> entrypoint runs a socat forwarder so the examples can use plain bridge networking with port `3080`
> published. See [security.md](docs/security.md) and the
> [deployment guide](docs/deployment.md) for details.

## Documentation

| Document | Contents |
|---|---|
| [docs/deployment.md](docs/deployment.md) | Deployment & maintenance: prerequisites, Compose, Quadlet, auto-update, remote access, offline use, FAQ |
| [docs/security.md](docs/security.md) | Security notes: network exposure tradeoff, credentials, trusted workloads |
| [docs/build.md](docs/build.md) | Build configuration: build args, version pinning, reproducible builds |
| [docs/releasing.md](docs/releasing.md) | Image tags, release workflow (GitHub Releases + version alignment), first-release manual steps |
| [docs/design.md](docs/design.md) | Design references and related projects |
| [docs/development.md](docs/development.md) | Directory structure and local development |

## License

[MIT](LICENSE)
