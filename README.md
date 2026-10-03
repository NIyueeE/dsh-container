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
| Toolchain | Node.js 22 LTS, pnpm, uv, Rust/cargo (+ rustfmt/clippy), git + git-lfs, build-essential, Caddy, podman + crun, gh — image-owned real binaries, upgraded with the image |
| Agent CLI tools | ripgrep, fd, python3, zip, openssh-client, tmux, sqlite3, vim.tiny/nano, less, rsync, wget, tree, htop, tzdata, patch — baked into the system layer, so a fresh container never re-downloads them (runtime `apt install` would be lost on recreation) |
| Nested containers | podman in-container (rootless) with `XDG_RUNTIME_DIR`, subuid/subgid and the network/sysctl defaults preconfigured; the host runtime must allow unprivileged user namespaces + `/dev/fuse` + `/dev/net/tun` and must not mask the container's `/proc` (`--security-opt unmask=ALL`, Quadlet `Unmask=ALL`, Docker `systempaths=unconfined`); resource limits (`--memory`/`--cpus`) inside nested containers are not enforced (cgroup v2 constraint) — see [docs/deployment.md](docs/deployment.md) § In-container podman |
| dsh | Built from the official source tag into `/opt/deepseek-harness` (`DSH_TAG` pinnable); no runtime auto-update |
| Exposure | Caddy reverse proxy (`0.0.0.0:3081` → dsh's `127.0.0.1:3080`) with optional basic auth |
| Supervisor | `dsh web` auto-restarts on exit; `docker exec dsh dsh-restart` restarts it manually |
| Remote compatibility | One container-adapt plugin (`container/plugin/`, mounted via `dsh --patch`): session-cookie bootstrap inside dsh, headless-hostile "Open config file" button hidden (`describe` reports no local document), upstream's `__DSH_TRANSPORT__` transport-owner declaration injected into the served index (remote settings/credentials), and `/container-assets/*` serving the build-time-extracted images |
| Observability | OCI labels, `HEALTHCHECK` (curl 3080 + 3081) |
| Runtime user | uid 1000 (`dsh`), passwordless sudo; `/home/dsh` is the persisted user layer |

## Container-adapt plugin

All container-side adaptation of upstream dsh lives in **one Cordis plugin**, shipped with the
image at `/opt/dsh-container-plugin` and mounted into the web profile via `dsh --patch`:

- **Session-cookie bootstrap** — the plugin exchanges dsh's one-time login token inside the dsh
  process and writes the cookie for the proxy to inject; browsers never see a token.
- **Hidden settings-document button** — "Open config file" has no headless fallback upstream and
  would spawn `xdg-open` into nothing in a container. The plugin makes `settings/describe`
  report `hasDocument: false`, so the button never renders (upstream's own UI logic). Settings
  persist on the mounted volume under `~/.dsh` (upstream v0.1.7+ keeps them per profile in
  `~/.dsh/profiles/<profile>/cordis.patch.yml`; the legacy `settings.yaml` is imported once).
- **Transport-owner declaration** — upstream's browser code computes `isLoopback` from
  `location.hostname` unless a shell declares itself the transport owner. The plugin injects
  `globalThis.__DSH_TRANSPORT__={ownsHost:true}` into the served index — the same declaration
  upstream's desktop shell and worker-preview tunnel use — so settings/credentials work through
  the proxy with no change to upstream build artifacts.
- **Payload post-processing** — three build-time steps run after `pnpm run build:official`:
  images inlined at ≥ 100 KiB are extracted to `/container-assets/<content-hash>` (served
  `immutable` by the plugin, fetched only when the screen that uses them opens), the client
  bundles are minified with esbuild, and the `.dsh-build` record is refreshed so it keeps
  matching the delivered artifacts.

This plugin is the single adaptation maintenance point. When upstream ships an API that makes part
of it redundant, the release pipeline deletes that part automatically — the removal shows up in
that release's commit list (see [docs/upstream-contract.md](docs/upstream-contract.md)
§ Simplification triggers).

## Networking & security

- **Port model** — `dsh web` listens on `127.0.0.1:3080` (upstream rejects `--host 0.0.0.0`); the
  exposed port is `3081`, published on host loopback by the examples.
- **The proxy is the security boundary** — Caddy rewrites `Host`/`Origin` to loopback, so remote
  browsers pass dsh's `/api` trust fence, including settings/credentials methods that are otherwise
  loopback-only. Anyone who can reach `3081` gets full control: enable basic auth
  (`DSH_PROXY_USER`/`DSH_PROXY_PASSWORD`, set together or the supervisor refuses to start) and keep
  the port firewalled.
- **Session bootstrapped** — the container-adapt plugin exchanges dsh's one-time login token
  inside the dsh process at startup and the proxy injects the session cookie into every proxied
  request; browsers never see a token.
- **Streams, payload & caching** — SSE/WebSocket pass through unbuffered (verified against Caddy
  2.6) and dsh's 2 s heartbeat survives the hop. The client bundles are post-processed at build
  time, so a cold page load is **≈1.5 MiB gzip** instead of ≈5.7 MiB: the combined client-plugin
  bundle drops from 5.07 MiB to ≈0.9 MiB gzip (images inlined at ≥ 100 KiB are extracted and
  fetched only when their screen opens, and the bundles are minified). The index is `no-store`
  while the content-hashed `/assets/*` tree is served `immutable`, so repeat visits are cheap.
- **Telemetry off by default** — the entrypoint sets `DSH_TELEMETRY_MODE=DISABLED`, so the OTel
  feedback uploader never sends anything unless you opt back in. Separate from it, upstream's
  DeepSeek session-log contributor is **on by default** and attaches session-log suffixes to
  DeepSeek API requests — see [docs/security.md](docs/security.md) for what it sends and how to
  turn it off.
- **Extra args** — pass `dsh web` arguments through the container command, e.g.
  `["--port", "8080"]` (internal port only; exposed port stays `3081`).

For WAN access, terminate TLS in front of `3081` (the docs include a working nginx config with
WebSocket headers and raised timeouts) — see [docs/deployment.md](docs/deployment.md) and
[docs/security.md](docs/security.md).

## Environment variables

| Variable | Default | Description |
|---|---|---|
| `DSH_PROXY_USER` / `DSH_PROXY_PASSWORD` | *(empty)* | Basic auth on the exposed proxy (recommended for any non-loopback deployment); set both or neither |
| `DSH_TELEMETRY_MODE` | `DISABLED` | OTel feedback-upload policy; `FEEDBACK_ONLY` restores the upstream default (uploads on explicit feedback), `DISABLED` keeps the OTel path local. It does **not** control the DeepSeek session-log contributor ([security.md](docs/security.md)) |

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
| [docs/development.md](docs/development.md) | Directory structure and local development |

## License

[MIT](LICENSE)
