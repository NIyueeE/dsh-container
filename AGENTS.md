# AGENTS.md — dsh Container Image

Guidelines for AI agents (and humans) working on this repository. Read this before editing; it
explains the runtime architecture, the upstream constraints that shape it, and the conventions
that keep docs and examples aligned with code.

## What this repository is

A container image for [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) (`dsh`),
built on `debian:13-slim` and published to GHCR as `ghcr.io/niyueee/dsh-container`. Users pull the
image and run it with Docker/Podman; this repo is not an application you run directly.

## Repository layout

| Path | Purpose |
|---|---|
| `Containerfile` | Image build: Debian slim base, Node LTS + pnpm, image-owned rust/uv toolchain (`/opt/rust`, `/usr/local/bin` real binaries), apt podman/Caddy/gh, source-built dsh (`/opt/deepseek-harness`), entrypoint |
| `container/entrypoint.sh` | Container entrypoint, installed as `/usr/local/bin/entrypoint` |
| `container/dsh-web.sh` | Stack supervisor: dsh web + session bootstrap (token → cookie) + Caddy reverse proxy (auto-restart), installed as `/usr/local/bin/dsh-web` |
| `container/dsh-restart.sh` | Restart dsh web from inside the container, installed as `/usr/local/bin/dsh-restart` |
| `container/dsh-client-patch.sh` | Idempotent client-side compatibility patch, installed as `/usr/local/bin/dsh-client-patch` |
| `container/dsh-migrate-legacy.sh` | One-time startup migration: removes the legacy npm-installed dsh from old data volumes, installed as `/usr/local/bin/dsh-migrate-legacy` |
| `examples/compose.yaml`, `examples/dsh.container` | Orchestration examples; they pull the published image and are the user-facing deployment reference |
| `docs/*.md` | User-facing guides (English): deployment, security, build, releasing, design, development |
| `README.md` / `README.zh.md` | Project README + Chinese translation. `README.md` is the single source of truth |
| `.github/workflows/image.yml` | CI: build + smoke test always; push to GHCR + GitHub Release only on `dsh-v*` tags (matching upstream dsh tags) |
| `.github/workflows/upstream-tag.yml` | Scheduled watcher: compares the newest upstream `dsh-v*` tag with this repo's and opens/closes a tracker issue (Dependabot cannot watch another repo's git tags) |
| `.github/dependabot.yml` | Dependabot version updates: weekly `github-actions` + `docker` ecosystems (action pins, base image) |
| `justfile` | Local build / debug / restart commands (podman or docker) |

## Runtime architecture (understand before editing)

The entrypoint (`container/entrypoint.sh`) does, in order:

1. Restores `HOME` from passwd — containers run with a numeric `USER 1000`, so Docker does not set
   `HOME` (npm/uv/cargo need it).
2. Three-zone layout (the hermes-agent pattern): the image owns the whole toolchain as read-only
   system layer — dsh at `/opt/deepseek-harness`, uv/pnpm and the rustup proxies as real binaries
   in `/usr/local/bin`, the Rust toolchain tree in `/opt/rust`. The `/home/dsh` volume holds only
   data: dsh data stays at upstream's `~/.dsh` (no `DSH_HOME` override), the process cwd is `$HOME`
   itself (dsh creates directories under it as needed), and writable caches/user-installed tools
   live under `$HOME` (`CARGO_HOME=~/.cargo`, uv data in `~/.local/share/uv`,
   `PNPM_HOME=~/.local/share/pnpm`). Tool upgrades happen by image upgrade; a volume can never
   shadow image-provided tools. PATH is image-first (`/usr/local/bin` before `$HOME/.local/bin`)
   with user directories last, and the entrypoint runs `dsh-migrate-legacy` to remove the
   npm-installed dsh that pre-source-build images (v0.2.x) left inside old data volumes
   (idempotent, non-blocking). Toolchain copies seeded into volumes by even older images are
   inert (shadowed by PATH) — manual cleanup commands ship in the release notes.
3. Parses `--port <N>` / `--port=<N>` (default 3080) and rejects `0` and `3081`.
4. `dsh-web` then brings up the whole service stack (it is the container's supervisor — see
   `container/dsh-web.sh`): it starts `dsh web` on `127.0.0.1:$DSH_WEB_PORT` (output mirrored into
   the container log), exchanges the one-time `?token=...` login URL that `dsh web` prints for a
   signed session cookie, generates the Caddyfile, and starts a **Caddy reverse proxy** on
   `0.0.0.0:3081` that rewrites `Host`/`Origin` to loopback, injects the session cookie into every
   proxied request, and gzip-compresses UI assets. Browsers never handle the token; authentication
   is Caddy's job: `DSH_PROXY_USER` + `DSH_PROXY_PASSWORD` add basic auth (Caddyfile `basicauth`
   directive on the distro caddy 2.6 — renamed `basic_auth` upstream in 2.7; password bcrypt-hashed
   via `caddy hash-password`, fed over stdin). Setting only one auth variable is a startup error,
   not a silent no-auth fallback. The Caddyfile is generated at runtime into
   `/tmp/dsh-caddy/Caddyfile`; Caddy restarts itself if it crashes (config errors still fail fast
   at startup).
5. `dsh-web` supervises `dsh web`: if it exits or crashes it is restarted automatically, and the
   session cookie survives restarts because dsh's signing secret is persisted in the volume (the
   supervisor re-exchanges only when the old cookie is no longer accepted). The container has no
   browser, so `dsh-web` appends `--no-open` unless the caller already passed it. Before every
   `dsh web` launch, `dsh-web` runs `dsh-client-patch`, an idempotent compatibility patch for
   upstream's browser-side loopback gate (settings/credentials) and a `crypto.randomUUID`
   polyfill for plain-HTTP LAN use. Inside the container, `dsh-restart` can be used to restart
   dsh web without restarting the whole container.

### Hard constraints from upstream dsh (do not fight these)

- **Upstream dsh (both source tags and main) rejects `--host 0.0.0.0`** (intentional safety
  design). dsh always listens on `127.0.0.1` in this image; the Caddy proxy is the exposure
  mechanism.
- **The `/api` browser-trust fence checks HTTP headers only** (`Host`/`Origin`/`sec-fetch-site`),
  never the TCP source address. The proxy's loopback rewrite therefore passes every endpoint —
  **including `PRIVILEGED_METHODS`** (`settings/describe`, `settings/update`, `credentials.*`,
  `agentPreset.*`, `host.pickDirectory`/`host.openPath`, `llm.discoverModels`) that upstream
  hard-pins to loopback via an empty trust list. Upstream also requires a browser session
  (one-time `?token=...` login URL → signed cookie backed by a signing secret persisted in the
  volume). This image absorbs the flow: the supervisor exchanges the token at startup and Caddy
  injects the cookie into every proxied request, so reaching `3081` means a fully authenticated
  session — the **proxy is the security boundary**. Never present this as "secure by default";
  `DSH_PROXY_USER`/`DSH_PROXY_PASSWORD` basic auth is the recommended control, and dsh's own
  fence still guards direct `3080` access from same-network containers (that port is not
  published).
- **Upstream's browser code still gates settings/credentials on `location.hostname`**, so the Caddy
  header rewrite alone is not enough for the settings UI. `dsh-client-patch` makes the browser treat
  a proxied remote session as loopback and injects a `crypto.randomUUID` polyfill; it is best-effort
  and skips with a warning if upstream changes the bundle strings.
- dsh's agent workspace is the process cwd — the entrypoint must `cd "$HOME"` (or, for tests,
  whichever directory it is configured to use).

## Conventions

- **Runtime user is fixed** to `dsh` (uid 1000) on the Debian slim base. Build steps may use
  `/home/dsh` directly; the entrypoint still restores `HOME` from passwd at runtime for dsh and
  tooling.
- **Layer defaults are fixed, not configurable surface**: dsh data at `~/.dsh` (upstream default),
  cwd `$HOME`, writable user areas `~/.cargo` (cargo registry/cache + `cargo install` binaries),
  `~/.local/bin`, `~/.local/share/pnpm` (pnpm store + user globals). Do not turn these paths into
  entrypoint configuration variables. The whole `/home/dsh` directory is the persistence boundary
  but holds only data — the image owns the entire toolchain (uv/pnpm/cargo real binaries in
  `/usr/local/bin`, Rust toolchain tree in `/opt/rust`, dsh source/build artifacts in
  `/opt/deepseek-harness`), so tools are upgraded by image upgrade, never by mutating the volume.
- **`dsh` has passwordless sudo** via the `sudo` group (`%sudo ALL=(ALL) NOPASSWD:ALL`). This is
  intentional for a development container, but it means uid 1000 can reach root; treat the
  container root as reachable by the agent.
- **podman is installed for in-container rootless work, with subuid/subgid configured.** Nested
  rootless containers additionally depend on the host Docker/Podman seccomp and user-namespace
  settings — docs must not promise that `podman run` always works inside this image.
- **Ports**: exposed/external port is `3081`; `127.0.0.1:3080` is dsh's internal port only. Keep
  them distinct everywhere. The proxy binds `0.0.0.0:3081` because it differs from dsh's port —
  do not reintroduce container-IP binding tricks. The examples publish it on host loopback
  (`127.0.0.1:3081:3081`) — LAN/public exposure is an explicit step (the plain-LAN variant is
  documented next to the publish line).
- **Remote access is proxy-only**: the Caddy header rewrite is the only exposure path. Do not
  add host-trust bypasses; basic auth (`DSH_PROXY_USER`/`DSH_PROXY_PASSWORD`) is the access
  control.
- **Keep examples and docs in sync with code.** Changing ports, env vars, defaults, or entrypoint
  behavior requires updating all of: `container/entrypoint.sh` header, `Containerfile` comments,
  `examples/compose.yaml`, `examples/dsh.container`, `README.md` + `README.zh.md`,
  `docs/deployment.md`, `docs/security.md`, and the CI smoke test in `.github/workflows/image.yml`
  (it publishes `3081:3081` and curls `127.0.0.1:3081`).
- **README.md is the single source of truth**; `README.zh.md` must mirror its structure exactly
  (same headings, links, and code fences; translate prose only — never code, commands, URLs,
  env vars, or file paths).
- Code comments are Chinese; user-facing docs are English.
- Commit messages follow the repo style: `feat:`, `fix:`, `docs:`, `ci:`.

## Common tasks

```sh
just build      # build ghcr.io/niyueee/dsh-container:local (podman or docker)
just debug      # run in the foreground with port 3081 published
just restart-dsh # restart dsh web inside the running "dsh" container
```

- The justfile passes `--format docker` only for podman (Docker has no such flag). podman needs it
  so `HEALTHCHECK` survives; GHCR images use the docker format.
- Releasing: push a `dsh-v*` tag matching the upstream dsh repository tag → CI builds from
  that upstream tag, smoke-tests amd64, then publishes amd64 by digest; arm64 builds in parallel
  on GitHub's free native Arm runner (`ubuntu-24.04-arm`), and a merge job combines both into a
  multi-arch image tagged `dsh-v*` + `<sha>` + `latest`, then creates a GitHub Release with the
  same tag name. No QEMU emulation anywhere. Upstream tags are watched automatically: the
  scheduled `.github/workflows/upstream-tag.yml` opens a tracker issue when upstream publishes a
  new `dsh-v*` tag and closes it once the tag is mirrored here; `.github/dependabot.yml` keeps
  action pins and the base image updated.

## Validation checklist before committing

1. `bash -n container/*.sh` (and `shellcheck` if available)
2. Examples parse: `docker compose -f examples/compose.yaml config --quiet` (or podman-compose)
3. README/README.zh parity: equal heading count, link count, and code-fence count
4. `just --list` parses with both the podman and docker branches in mind; Docker-only hosts must
   not receive podman-only flags.
5. If you changed networking/trust behavior, verify end to end in a container: parse the
   `?token=...` login URL from `dsh web` logs, exchange it through the proxy for the browser
   cookie, then a privileged method (`POST /api/settings/describe`) must return **200 with the
   cookie and 401 without it** (header rewrite + browser session both work). With
   `DSH_PROXY_USER`/`DSH_PROXY_PASSWORD` set, the same flow must return **401 without basic
   credentials and succeed with them**, and setting only one auth variable must exit nonzero.
   Always test inside the built image (the dev machine may lack `caddy`).
6. If you touched the client patch, run the `dsh-client-patch` validate step and verify the served
   index.html contains the `crypto.randomUUID` polyfill; for the connection bundle, extract the
   `/plugins/??@deepseek-ai/dsh-client-connection/client.js&rev=...` URL from the served index and
   verify it contains the `isLoopback` patch.
