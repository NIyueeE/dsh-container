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
# open http://127.0.0.1:3081/ in your local browser (the proxy redirects to dsh's launch token)
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
the image. The first visit is redirected to dsh's launch token and the browser keeps the session
cookie; there is no separate login form.

## What's inside

| Component | Description |
|---|---|
| Base image | `debian:13-slim` (pinned; overridable via the `BASE_IMAGE` build arg) |
| Toolchain | Node.js 22 LTS, pnpm, uv, Rust/cargo (+ rustfmt/clippy), git + git-lfs, build-essential, Caddy, podman + crun, gh, yq — image-owned real binaries, upgraded with the image |
| Agent CLI tools | ripgrep, fd, python3, zip, openssh-client, tmux, sqlite3, vim.tiny/nano, less, rsync, wget, tree, htop, tzdata, patch, plus a diagnostics set (dig/nc/socat/traceroute/iperf3/nft, file, ncdu, strace, zstd/lz4, bc, moreutils, pv, uuid-runtime), xdg-user-dirs (UI default workspace) and dev tooling (just, shellcheck) — baked into the system layer, so a fresh container never re-downloads them (runtime `apt install` would be lost on recreation) |
| Nested containers | podman in-container (rootless) with `XDG_RUNTIME_DIR`, subuid/subgid and the network/sysctl defaults preconfigured; the host runtime must allow unprivileged user namespaces + `/dev/fuse` + `/dev/net/tun` and must not mask the container's `/proc` (`--security-opt unmask=ALL`, Quadlet `Unmask=ALL`, Docker `systempaths=unconfined`); resource limits (`--memory`/`--cpus`) inside nested containers are not enforced (cgroup v2 constraint) — see [docs/deployment.md](docs/deployment.md) § In-container podman |
| dsh | Built from the official source tag into `/opt/deepseek-harness` (`DSH_TAG` pinnable); no runtime auto-update |
| Exposure | Caddy reverse proxy (`0.0.0.0:3081` → dsh's `127.0.0.1:3080`); preserves the browser `Host`/`Origin`, redirects the first visit to dsh's login token, and keeps optional basic auth |
| Supervisor | `dsh web` auto-restarts on exit; `docker exec dsh dsh-restart` restarts it manually |
| Remote compatibility | One container-adapt plugin (`container/plugin/`, mounted via `dsh --patch`): writes dsh's launch token for the proxy login redirect (the browser holds the session cookie), hides the headless-hostile "Open config file" button (`describe` reports no local document), keeps the upstream `__DSH_TRANSPORT__` declaration for older tags, and serves the build-time-extracted images from `/container-assets/*` |
| Observability | OCI labels, `HEALTHCHECK` (curl 3080 + 3081) |
| Runtime user | uid 1000 (`dsh`), passwordless sudo; `/home/dsh` is the persisted user layer |

## Container-adapt plugin

All container-side adaptation of upstream dsh lives in **one Cordis plugin**, shipped with the
image at `/opt/dsh-container-plugin` and mounted into the web profile via `dsh --patch`:

- **Launch-token redirect** — the plugin writes dsh's process launch token to
  `/tmp/dsh-caddy/launch-token`; Caddy 302s a browser without a session cookie to `/?token=...`, and
  dsh sets an `HttpOnly; SameSite=Strict` cookie. The container never injects or rewrites the
  session; the browser holds it.
- **Hidden settings-document button** — "Open config file" has no headless fallback upstream and
  would spawn `xdg-open` into nothing in a container. The plugin makes `settings/describe`
  report `hasDocument: false`, so the button never renders (upstream's own UI logic). Settings
  persist on the mounted volume under `~/.dsh` (upstream v0.1.7+ keeps them per profile in
  `~/.dsh/profiles/<profile>/cordis.patch.yml`; the legacy `settings.yaml` is imported once).
- **Transport-owner declaration (compatibility)** — older upstream tags compute `isLoopback` from
  `location.hostname` unless a shell declares itself the transport owner; the plugin still
  contributes the `__DSH_TRANSPORT__ = { ownsHost: true }` row for them. On 0.2.x its only
  consumer is the settings-document controller, which is already hidden, and Caddy now preserves
  Host/Origin — so it is not a security mechanism.
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
- **The proxy preserves the fence** — Caddy forwards the browser `Host`/`Origin` unchanged; dsh's
  `/api` fence is real. External authorities must be listed in `DSH_TRUSTED_HOST` (or derived from
  `DSH_PUBLIC_URL`); Caddy rejects any other Host with 403, which is what stops DNS rebinding.
  Anyone who can reach `3081` can log in: enable basic auth (`DSH_PROXY_USER`/`DSH_PROXY_PASSWORD`,
  set together or the supervisor refuses to start) and keep the port firewalled. The
  `/api/remote.mux` WebSocket is exempt from basic auth (browsers do not reliably attach
  `Authorization` to upgrades) and is authenticated by the browser's `SameSite=Strict` cookie.
- **Session held by the browser** — the first visit without a cookie is 302'd to dsh's launch token;
  dsh sets the session cookie and the browser sends it back. There is no server-side cookie
  injection. DeepSeek account sign-in still requires a loopback browser origin (an SSH tunnel),
  not a public hostname — see [docs/deployment.md](docs/deployment.md) § DeepSeek account sign-in.
- **Streams, payload & caching** — SSE/WebSocket pass through unbuffered (verified against Caddy
  2.6) and dsh's 2 s heartbeat survives the hop. The client bundles are post-processed at build
  time, so a cold page load measured in a headless browser is **≈1.6 MiB on the wire** instead of
  ≈5.8 MiB: the combined client-plugin bundle drops from 5.06 MiB to ≈1.0 MiB gzip (images inlined at ≥ 100 KiB are extracted and
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
| `DSH_PROXY_USER` / `DSH_PROXY_PASSWORD` | *(empty)* | Basic auth on the exposed proxy (recommended for any non-loopback deployment); set both or neither. `/api/remote.mux` is exempt and uses the dsh session cookie |
| `DSH_PUBLIC_URL` | `http://127.0.0.1:3081/` | Browser-facing root advertised to dsh/agent context and used by the launch-token URL. Set it to the real external URL for LAN/public; it grants no trust |
| `DSH_TRUSTED_HOST` | *(empty; derived from `DSH_PUBLIC_URL`)* | Comma-separated extra authorities (host or host:port) accepted by dsh's fence and Caddy's Host allowlist |
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
