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
| `container/dsh-web.sh` | Stack supervisor: dsh web (mounted with the container-adapt plugin overlay) + session-cookie wait + Caddy reverse proxy (auto-restart), installed as `/usr/local/bin/dsh-web` |
| `container/dsh-restart.sh` | Restart dsh web from inside the container, installed as `/usr/local/bin/dsh-restart` |
| `container/plugin/` | The single container-adaptation point, installed at `/opt/dsh-container-plugin`: the runtime Cordis plugin (`index.js` + `overlay.yml`, mounted via `dsh --patch`) bootstraps the session cookie inside the dsh process, degrades "open settings document" to a `/download/settings.yaml` hint (no `xdg-open`), serves that download endpoint, and `scripts/patch-client.js` applies the browser-side `isLoopback` patch to the built bundle (build-time and before every start) |
| `examples/compose.yaml`, `examples/dsh.container` | Orchestration examples; they pull the published image and are the user-facing deployment reference |
| `docs/*.md` | User-facing guides (English): deployment, security, build, releasing, design, development |
| `README.md` / `README.zh.md` | Project README + Chinese translation. `README.md` is the single source of truth |
| `.github/workflows/image.yml` | CI: build + smoke test always; push to GHCR + GitHub Release only on `dsh-v*` tags (matching upstream dsh tags) |
| `.github/workflows/upstream-tag.yml` | Scheduled watcher: compares the newest upstream `dsh-v*` tag with this repo's and opens a tracker issue (Dependabot cannot watch another repo's git tags); on a new tag it also `repository_dispatch`-es `release-prep.yml`. It closes a tracker issue only once that tag's push has actually produced an `image.yml` run (a tag that never triggered the pipeline keeps the issue open with a hint) |
| `.github/workflows/release-prep.yml` | Automated release preparation: contract check → codex agent (drift repair **and** an adaptation review on every run — upstream changes that make a hack redundant are deleted, see `docs/upstream-contract.md` § Simplification triggers) → build + smoke on the repaired tree → push the `dsh-v*` tag via a fine-grained PAT secret (must carry the Workflows: read and write permission; post-push confirmation that the tag push actually triggered `image.yml`, failing the run otherwise; manual-instruction fallback on the tracker issue when no PAT is configured) |
| `tests/smoke.sh` | End-to-end image smoke test, shared by `image.yml`, `release-prep.yml`, and `just test` (DOCKER=podman aware) |
| `tests/contract.sh` | Static upstream-contract check — the machine form of `docs/upstream-contract.md`: greps an upstream tag for patch anchors, CLI flags, and the request fence before any image is built |
| `prompts/release-prep.md` | System prompt for the headless codex agent that repairs contract drift in the `release-prep.yml` prep job |
| `docs/upstream-contract.md` | The upstream contract: what this image depends on, where each item is enforced, and the drift-update protocol the agent follows |
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
   with user directories last. Toolchain copies and the npm-installed dsh that pre-source-build
   images (v0.2.x) seeded into volumes are inert (shadowed by PATH); manual cleanup commands
   ship in the release notes. The entrypoint
   also defaults `DSH_TELEMETRY_MODE=DISABLED` (user-overridable): dsh's OTel feedback uploader
   (upstream default `FEEDBACK_ONLY` — exports the session prefix on explicit feedback) never
   sends data out of the container unless the user opts in.
3. Parses `--port <N>` / `--port=<N>` (default 3080) and rejects `0` and `3081`.
4. `dsh-web` then brings up the whole service stack (it is the container's supervisor — see
   `container/dsh-web.sh`): it starts `dsh web` on `127.0.0.1:$DSH_WEB_PORT` (output mirrored into
   the container log) mounted with the container-adapt plugin overlay
   (`dsh --patch /opt/dsh-container-plugin/overlay.yml --profile web ...` — the `web` alias
   rejects parent flags upstream, so the root `--profile web` form is required). The plugin
   bootstraps the session cookie inside the dsh process (token → cookie, reusing a still-valid
   cookie) and
   writes it to `/tmp/dsh-caddy/session-cookie`; `dsh-web` waits for the file, generates the
   Caddyfile, and starts a **Caddy reverse proxy** on
   `0.0.0.0:3081` that rewrites `Host`/`Origin` to loopback and injects the session cookie into
   every proxied request (UI assets are gzip-compressed by dsh's own webserver; Caddy does not
   re-compress). Browsers never handle the token; authentication
   is Caddy's job: `DSH_PROXY_USER` + `DSH_PROXY_PASSWORD` add basic auth (Caddyfile `basicauth`
   directive on the distro caddy 2.6 — renamed `basic_auth` upstream in 2.7; password bcrypt-hashed
   via `caddy hash-password`, fed over stdin). Setting only one auth variable is a startup error,
   not a silent no-auth fallback. The Caddyfile is generated at runtime into
   `/tmp/dsh-caddy/Caddyfile`; Caddy restarts itself if it crashes (config errors still fail fast
   at startup).
5. `dsh-web` supervises `dsh web`: if it exits or crashes it is restarted automatically, and the
   session cookie survives restarts because dsh's signing secret is persisted in the volume (the
   plugin reuses the old cookie while it stays valid). The container has no
   browser, so `dsh-web` appends `--no-open` unless the caller already passed it. Before every
   `dsh web` launch, `dsh-web` runs `node /opt/dsh-container-plugin/scripts/patch-client.js`, an
   idempotent build-artifact patch for upstream's browser-side loopback gate (settings/credentials;
   upstream's `trustedHosts` covers only the server-side fence). Inside the container,
   `dsh-restart` can be used to restart dsh web without restarting the whole container.

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
  volume). This image absorbs the flow: the container-adapt plugin exchanges the token at dsh
  startup and Caddy injects the cookie into every proxied request, so reaching `3081` means a
  fully authenticated session — the **proxy is the security boundary**. Never present this as
  "secure by default";
  `DSH_PROXY_USER`/`DSH_PROXY_PASSWORD` basic auth is the recommended control, and dsh's own
  fence still guards direct `3080` access from same-network containers (that port is not
  published).
- **Upstream's browser code still gates settings/credentials on `location.hostname`**, so the Caddy
  header rewrite alone is not enough for the settings UI. `scripts/patch-client.js` (in
  `container/plugin/`) makes the browser treat a proxied remote session as loopback; it is
  best-effort and skips with a warning if upstream changes the bundle strings. (No `index.html`
  modification is needed — upstream ships its own insecure-context `randomUuid()` in
  `@deepseek-ai/dsh-util-crypto`.)
- **`settings/openSettingsDocument` has no headless fallback upstream** (unlike preset/workspace
  opens, which check `canOpenPath`): the plugin `disabled`s the upstream `settings-controller` row
  and replaces it via the constructor `internals` (openPath/openTextFile/canOpenPath), degrading
  the button to a message pointing at `/download/settings.yaml`. That endpoint is registered via
  `webServer.register` and applies `ctx.connection.requestRejection` (same Host/Origin + browser
  session checks as the `/api` fence), so direct `3080` access without a cookie is rejected.
- dsh's agent workspace is the process cwd — the entrypoint must `cd "$HOME"` (or, for tests,
  whichever directory it is configured to use).

## Push & release discipline

- **Never push.** The agent works in the local working tree only. Pushing branches, tags, or
  main to the remote is **not allowed** without an explicit user instruction for that push.
- **Never tag or release on your own.** Creating/moving git tags and triggering release
  pipeline runs (image.yml publish builds, GitHub Releases) are user-only actions. A finished
  change is reported as local commit(s); the user decides when and how to push and release.
- Before implementing a user-facing change, **present the approach first** (what will change,
  why, and its cost) and wait for approval — do not research-and-build-and-ship in one pass.

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
just test       # smoke-test an already built image (tests/smoke.sh)
just contract dsh-v0.1.2-rc.1  # static upstream-contract check for one tag
```

- The justfile passes `--format docker` only for podman (Docker has no such flag). podman needs it
  so `HEALTHCHECK` survives; GHCR images use the docker format.
- Releasing: push a `dsh-v*` tag matching the upstream dsh repository tag → CI builds from
  that upstream tag, smoke-tests amd64, then publishes amd64 by digest; arm64 builds in parallel
  on GitHub's free native Arm runner (`ubuntu-24.04-arm`), and a merge job combines both into a
  multi-arch image tagged `dsh-v*` + `<sha>` + `latest`, then creates a GitHub Release with the
  same tag name. No QEMU emulation anywhere. Upstream tags are watched automatically: the
  scheduled `.github/workflows/upstream-tag.yml` opens a tracker issue when upstream publishes a
  new `dsh-v*` tag and closes it once the tag is mirrored here and its push actually triggered
  `image.yml`; on a new tag it also dispatches
  `.github/workflows/release-prep.yml`, which runs the contract check, repairs drift with a
  headless codex agent and reviews the upstream diff for hack-simplification opportunities
  (`docs/upstream-contract.md` § Simplification triggers; see `prompts/release-prep.md`),
  re-validates with build + smoke, pushes
  the release tag, and confirms the push actually triggered `image.yml` (a fine-grained
  `RELEASE_PAT` needs the Workflows: read and write permission for that) — the manual `git tag`
  flow above remains the fallback. `.github/workflows/pat-trigger-probe.yml` can pre-verify the
  PAT's push-trigger capability on demand. `.github/dependabot.yml`
  keeps action pins and the base image updated.

## Validation checklist before committing

1. `bash -n container/*.sh tests/*.sh` (and `shellcheck` if available)
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
6. If you touched the client patch, run the `patch-client.js` validate step: extract the
   `/plugins/??@deepseek-ai/dsh-client-connection/client.js&rev=...` URL from the served index and
   verify it contains the `isLoopback` patch (there is no `index.html` modification anymore — no
   polyfill is injected).
