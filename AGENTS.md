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
| `Containerfile` | Image build: base image, rustup/uv, global npm install of `@deepseek-ai/dsh`, entrypoint |
| `container/entrypoint.sh` | Container entrypoint, installed as `/usr/local/bin/entrypoint` |
| `container/dsh-update.sh` | Idempotent dsh auto-updater, installed as `/usr/local/bin/dsh-update` |
| `examples/compose.yaml`, `examples/dsh.container` | Orchestration examples; they pull the published image and are the user-facing deployment reference |
| `docs/*.md` | User-facing guides (English): deployment, security, build, releasing, design, development |
| `README.md` / `README.zh.md` | Project README + Chinese translation. `README.md` is the single source of truth |
| `.github/workflows/image.yml` | CI: build + smoke test always; push to GHCR + GitHub Release only on `v*` tags |
| `justfile` | Local build / debug / update-only commands (podman or docker) |

## Runtime architecture (understand before editing)

The entrypoint (`container/entrypoint.sh`) does, in order:

1. Restores `HOME` from passwd — containers run with a numeric `USER 1000`, so Docker does not set
   `HOME` (npm/uv/cargo need it).
2. Defaults `DSH_HOME=$HOME/dsh` and `DSH_WORKSPACE=$HOME/workspace` (→ `/home/codespace/...` on
   universal 6.x, `/home/vscode/...` on legacy 2.x), creates them, and `cd`s into the workspace
   (dsh's working directory is the agent's workspace).
3. Runs `dsh-update` unless `DSH_AUTO_UPDATE=0` (offline-safe; keeps the in-image version on failure).
4. Starts a socat forwarder: `0.0.0.0:3081` → `127.0.0.1:$PORT` (dsh's internal port, default 3080,
   parsed from `--port` args). The ports deliberately differ so socat can bind the wildcard address.
5. Starts `dsh web` with `--trusted-host` args derived from `DSH_TRUSTED_HOSTS` (space- or
   comma-separated `host[:port]` list) plus any extra container `command` args.

### Hard constraints from upstream dsh (do not fight these)

- **npm releases of `dsh` reject `--host 0.0.0.0`.** dsh always listens on `127.0.0.1` in this
  image; the socat forwarder is the exposure mechanism and the only supported way to reach the UI
  beyond loopback.
- **`/api` browser-trust fence**: `dsh web` returns HTTP 403 for any request whose `Host` header is
  neither loopback (`localhost`, `127.x`, `[::1]`) nor in `trustedHosts`. The container cannot
  auto-derive LAN trust (that only happens when dsh itself binds `0.0.0.0`), so
  `DSH_TRUSTED_HOSTS` / `--trusted-host` is the only way to allow non-loopback browsers.
- dsh's agent workspace is the process cwd — the entrypoint must `cd "$DSH_WORKSPACE"`.

## Conventions

- **Runtime user is uid 1000** (`codespace` on universal 6.x, `vscode` on legacy 2.x). Resolve it
  via `getent passwd`, never hardcode `/home/codespace` in runtime logic; the entrypoint derives
  defaults from `$HOME`. The Containerfile's directory-creation step must use the same resolution
  (`/etc/dsh-container-user`).
- **Do not bake `DSH_HOME`/`DSH_WORKSPACE` into the image `ENV`** — entrypoint-side defaults are
  what keep legacy 2.x base images working.
- **Ports**: exposed/external port is `3081`; `127.0.0.1:3080` is dsh's internal port only. Keep
  them distinct everywhere. Do not reintroduce the old container-IP binding hack
  (`hostname -I` + bind) — the port separation makes it unnecessary.
- **`--trusted-host`/`DSH_TRUSTED_HOSTS` entries must use the exposed port** (`host:3081`) in all
  examples and docs, because the fence matches the browser's `Host` header.
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
just build        # build ghcr.io/niyueee/dsh-container:local (podman or docker)
just debug        # run in the foreground with port 3081 published
just update-only  # run dsh-update in a throwaway container
```

- Build with `--format docker` (podman) so `HEALTHCHECK` survives (podman's default OCI format
  drops it). GHCR images use the docker format.
- Releasing: push a `v*` tag → CI builds, smoke-tests, then pushes `v*` + `<sha>` + `latest` and
  creates a GitHub Release. The first release ever needs a one-time manual GHCR visibility change
  to public (see `docs/releasing.md`).

## Validation checklist before committing

1. `bash -n container/entrypoint.sh`
2. Examples parse: `docker compose -f examples/compose.yaml config --quiet` (or podman-compose)
3. No stale references to the old design: `DSH_WEB_HOST`, `/dsh` or `/workspace` mount targets,
   port-`3080` host mappings (grep the repo)
4. README/README.zh parity: equal heading count, link count, and code-fence count
5. If you changed networking/trust behavior, verify end to end: run the entrypoint with a
   temporary `DSH_HOME`/`DSH_WORKSPACE` and `DSH_AUTO_UPDATE=0`, then curl the exposed port with
   loopback, trusted, and untrusted `Host` headers (expect 200 / 200 / 403). Note the dev machine
   may lack `socat` — stub it or test inside a container.
