# AGENTS.md — dsh Container Image

Guidelines for AI agents (and humans) working on this repository. Read this before editing; it
explains the runtime architecture, the upstream constraints that shape it, and the conventions
that keep docs and examples aligned with code.

## What this repository is

A container image for [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) (`dsh`),
built on `mcr.microsoft.com/devcontainers/universal` and published to GHCR as
`ghcr.io/niyueee/dsh-container`. Users pull the image and run it with Docker/Podman; this repo is
not an application you run directly.

## Repository layout

| Path | Purpose |
|---|---|
| `Containerfile` | Image build: base image, latest-LTS Node, user-level rustup/uv/pnpm, apt podman/Caddy, npm dsh, entrypoint |
| `container/entrypoint.sh` | Container entrypoint, installed as `/usr/local/bin/entrypoint` |
| `container/dsh-update.sh` | Idempotent dsh auto-updater, installed as `/usr/local/bin/dsh-update` |
| `examples/compose.yaml`, `examples/dsh.container` | Orchestration examples; they pull the published image and are the user-facing deployment reference |
| `docs/*.md` | User-facing guides (English): deployment, security, build, releasing, design, development |
| `README.md` / `README.zh.md` | Project README + Chinese translation. `README.md` is the single source of truth |
| `.github/workflows/image.yml` | CI: build + smoke test always; push to GHCR + GitHub Release only on `v*` tags |
| `justfile` | Local build / debug / update commands (podman or docker) |

## Runtime architecture (understand before editing)

The entrypoint (`container/entrypoint.sh`) does, in order:

1. Restores `HOME` from passwd — containers run with a numeric `USER 1000`, so Docker does not set
   `HOME` (npm/uv/cargo need it).
2. Uses fixed user-layer defaults under `$HOME`: dsh data stays at upstream's `~/.dsh` (no
   `DSH_HOME` override), the process cwd is `$HOME` itself (dsh creates directories under it as
   needed), Rust/cargo live in `~/.rustup` + `~/.cargo`, uv in `~/.local/bin`, and pnpm in
   `~/.local/share/pnpm`. The whole `/home/codespace` directory is mounted as the persistent user
   layer; the system layer (`/usr/local`, apt packages) is reset by image upgrades.
3. Runs `dsh-update` only when `DSH_AUTO_UPDATE=1` (default `0`; offline-safe — keeps the
   in-image version on failure).
4. Parses `--port <N>` / `--port=<N>` (default 3080) and rejects `0` and `3081`.
5. Starts a **Caddy reverse proxy**: listens on `0.0.0.0:3081` and forwards to dsh's
   `127.0.0.1:$PORT`, rewriting `Host`/`Origin` to loopback and gzip-compressing UI assets; it
   restarts itself if it crashes (config errors still fail fast at startup). The Caddyfile is
   generated at runtime into `/tmp/dsh-caddy/Caddyfile`; `DSH_PROXY_USER` + `DSH_PROXY_PASSWORD`
   add basic auth (Caddyfile `basicauth` directive on the distro caddy 2.6 — renamed `basic_auth`
   upstream in 2.7; password bcrypt-hashed via `caddy hash-password`, fed over stdin). Setting only
   one auth variable is a startup error, not a silent no-auth fallback.
6. Starts `dsh web` with any extra container `command` args (e.g. `--port`).

### Hard constraints from upstream dsh (do not fight these)

- **Both npm releases and upstream main of `dsh` reject `--host 0.0.0.0`** (intentional safety
  design). dsh always listens on `127.0.0.1` in this image; the Caddy proxy is the exposure
  mechanism.
- **The `/api` browser-trust fence checks HTTP headers only** (`Host`/`Origin`/`sec-fetch-site`),
  never the TCP source address. The proxy's loopback rewrite therefore passes every endpoint —
  **including `PRIVILEGED_METHODS`** (`settings.*`, `credentials.*`, `agentPreset.*`,
  `host.pickDirectory`/`host.openPath`, `llm.discoverModels`) that upstream hard-pins to loopback
  via an empty trust list. This is intentional: the **proxy is the security boundary** — anyone
  reaching `3081` can read/write all settings and credentials. Never present this as "secure by
  default"; `DSH_PROXY_USER`/`DSH_PROXY_PASSWORD` basic auth is the recommended control.
- dsh's agent workspace is the process cwd — the entrypoint must `cd "$HOME"` (or, for tests,
  whichever directory it is configured to use).

## Conventions

- **Runtime user is fixed** to `codespace` (uid 1000) on the pinned universal 6.1.1-noble base.
  Build steps may use `/home/codespace` directly; the entrypoint still restores `HOME` from
  passwd at runtime for dsh and tooling.
- **User-layer defaults are fixed, not configurable surface**: `~/.dsh` (upstream default),
  cwd `$HOME`, `~/.rustup` + `~/.cargo`, `~/.local/bin`, `~/.local/share/pnpm`. Do not turn
  these paths into entrypoint configuration variables. The whole `/home/codespace` directory is
  the persistence boundary; user-level tools are initialized by the image but then belong to the
  persisted volume.
- **podman is installed for in-container rootless work, with subuid/subgid configured.** Nested
  rootless containers additionally depend on the host Docker/Podman seccomp and user-namespace
  settings — docs must not promise that `podman run` always works inside this image.
- **Ports**: exposed/external port is `3081`; `127.0.0.1:3080` is dsh's internal port only. Keep
  them distinct everywhere. The proxy binds `0.0.0.0:3081` because it differs from dsh's port —
  do not reintroduce container-IP binding tricks.
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
just update-dsh # update the npm package in the running "dsh" container
```

- The justfile passes `--format docker` only for podman (Docker has no such flag). podman needs it
  so `HEALTHCHECK` survives; GHCR images use the docker format.
- Releasing: push a `v*` tag → CI builds, smoke-tests, then pushes `v*` + `<sha>` + `latest` and
  creates a GitHub Release.

## Validation checklist before committing

1. `bash -n container/entrypoint.sh` (and `shellcheck` if available)
2. Examples parse: `docker compose -f examples/compose.yaml config --quiet` (or podman-compose)
3. README/README.zh parity: equal heading count, link count, and code-fence count
4. `just --list` parses with both the podman and docker branches in mind; Docker-only hosts must
   not receive podman-only flags.
5. If you changed networking/trust behavior, verify end to end in a container: a loopback-only
   privileged method (`settings.describe`) must return **200 through the proxy** (header rewrite
   works); with `DSH_PROXY_USER`/`DSH_PROXY_PASSWORD` set, the same request must return **401
   without credentials and 200 with them**, and setting only one auth variable must exit nonzero.
   Always test inside the built image (the dev machine may lack `caddy`).
