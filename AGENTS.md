# AGENTS.md — dsh Container Image

Guidelines for AI agents (and humans) working on this repository. Read this before editing; it
explains the runtime architecture, the upstream constraints that shape it, and the conventions
that keep docs and examples aligned with code.

## What this repository is

A container image for [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) (`dsh`),
built on `debian:13-slim` and published to GHCR as `ghcr.io/niyueee/dsh-container`. Users pull the
image and run it with Docker/Podman; this repo is not an application you run directly.

**Global agent instructions** live at `~/.dsh/AGENTS.md` (`$DSH_HOME`, first) and
`~/.agents/AGENTS.md` (`$DSH_AGENTS_HOME`, second) — dsh loads both as a user-global baseline
before any project file. The image deliberately ships **no** default there; a copy-pasteable
container-environment note for that file lives in
[docs/deployment.md](docs/deployment.md#global-agent-instructions).

## Repository layout

| Path | Purpose |
|---|---|
| `Containerfile` | Image build: Debian slim base, Node LTS + pnpm, image-owned rust/uv toolchain (`/opt/rust`, `/usr/local/bin` real binaries), apt podman/crun/Caddy/gh + baked agent CLI tools (ripgrep/fd/python3/ssh/tmux/sqlite3/editors plus a diagnostics set: dig/nc/socat/traceroute/iperf3/nft, file, ncdu, strace, zstd/lz4, just, shellcheck), `uv tool`-installed yq (`/opt/uv-tools`), source-built dsh (`/opt/deepseek-harness`), entrypoint |
| `container/entrypoint.sh` | Container entrypoint, installed as `/usr/local/bin/entrypoint` |
| `container/dsh-web.sh` | Stack supervisor: dsh web (mounted with the container-adapt plugin overlay) + launch-token wait + Caddy reverse proxy with token login redirect (auto-restart, `caddy reload` on token rotation), installed as `/usr/local/bin/dsh-web` |
| `container/dsh-restart.sh` | Restart dsh web from inside the container, installed as `/usr/local/bin/dsh-restart` |
| `container/plugin/` | The single container-adaptation point, installed at `/opt/dsh-container-plugin`: the runtime Cordis plugin (`index.js` + `overlay.yml`, mounted via `dsh --patch`, with a Standard-Schema `Config`) writes dsh's launch token for Caddy's login redirect (the browser holds the session cookie), hides the headless-hostile "open settings document" button (wraps the `settingsController` service's `describe` so it reports `hasDocument: false`, plus a `documentPath` flip on pre-v0.1.7 tags; upstream's own UI never renders it), keeps the `__DSH_TRANSPORT__ = { ownsHost: true }` row for older tags (on 0.2.x only the settings-document controller consumes `isLoopback`, and it is hidden), serves the build-time-extracted images from `/container-assets/*`, and attaches a logger exporter so its own `ctx.logger` lines reach the container log; `scripts/` holds the three build-time post-processing steps (extract inline images, esbuild minification, build-record refresh) |
| `examples/compose.yaml`, `examples/dsh.container` | Orchestration examples; they pull the published image and are the user-facing deployment reference |
| `docs/*.md` | User-facing guides (English): deployment, security, build, releasing, development |
| `README.md` / `README.zh.md` | Project README + Chinese translation. `README.md` is the single source of truth |
| `.github/workflows/image.yml` | CI: build + smoke test always — **except** commits whose diff is only `*.md`/`LICENSE` (classified from the real push/PR diff, fail-closed, never for `dsh-v*` tags), which take a docs-only lane that still runs every validation step plus a relative-link check; push to GHCR + GitHub Release only on `dsh-v*` tags (matching upstream dsh tags). Tag builds additionally run `tests/contract.sh` as a publish gate (the only contract check a manually pushed tag gets) and compose the Release body from the upstream release notes quoted in a `<details>` block plus the auto-generated commit list — this image's own upgrade guidance lives in the docs, not on every Release page |
| `.github/workflows/upstream-tag.yml` | Scheduled watcher: compares the newest upstream `dsh-v*` tag with this repo's and opens a tracker issue (Dependabot cannot watch another repo's git tags); on a new tag it also `repository_dispatch`-es `release-prep.yml`, but re-dispatches a tag only when no `release-prep` run is queued or in progress (a repeat dispatch would queue a second build + smoke + agent run; retry after a failure stays). Its cron carries a deliberate ~6 h lead (`30 11 * * *`) because Actions' `schedule` lands 4–9 h late. It closes a tracker issue only once that tag's push has actually produced an `image.yml` run (a tag that never triggered the pipeline keeps the issue open with a hint). It also runs a **release health check** on our newest `dsh-v*` tag: a latest `image.yml` run that is missing, failed, or cancelled opens a "Release pipeline not published" issue, closed automatically once a run succeeds (the safety net for manually pushed tags, which skip release-prep) |
| `.github/workflows/release-prep.yml` | Automated release preparation: contract check → code-level diff triage (`tests/triage-diff.sh` admits the agent only on drift or adaptation-surface hits; fence drift and mis-dispatched tags fail fast) → dsh headless agent (drift repair + adaptation review, exits early with `NO_ACTION_NEEDED` when there is nothing to do — upstream changes that make a hack redundant are deleted, see `docs/upstream-contract.md` § Simplification triggers; its model/provider config is passed as a load-time `--patch` overlay, **never** as the flat `$DSH_HOME/settings.yaml`, which dsh v0.1.7+ only imports *after* the loader settles — too late for a fresh Actions home, the 2026-09-22 `dsh-v0.1.7-alpha.2` prep failure) → build + smoke on the repaired tree → push the `dsh-v*` tag via a fine-grained PAT secret (must carry the Workflows: read and write permission; post-push confirmation that the tag push actually triggered `image.yml`, failing the run otherwise; manual-instruction fallback on the tracker issue when no PAT is configured) |
| `tests/smoke.sh` | End-to-end image smoke test, shared by `image.yml`, `release-prep.yml`, and `just test` (DOCKER=podman aware) |
| `tests/contract.sh` | Static upstream-contract check — the machine form of `docs/upstream-contract.md`: greps an upstream tag for patch anchors, CLI flags, and the request fence before any image is built |
| `tests/triage-diff.sh` | Code-level agent admission gate: contract verdict + complete upstream changed-file list → decides whether the release-prep agent enters (drift or adaptation-surface hit), or the run proceeds without it |
| `tests/validate-docs.py` | Stdlib-only doc gate extracted from `image.yml`: `links` (every relative doc link resolves) and `parity` (README/README.zh heading, link and code-fence counts); run by CI and by `just lint` |
| `prompts/release-prep.md` | System prompt for the dsh headless agent that repairs contract drift in the `release-prep.yml` prep job |
| `docs/upstream-contract.md` | The upstream contract: what this image depends on, where each item is enforced, and the drift-update protocol the agent follows |
| `.github/dependabot.yml` | Dependabot version updates: weekly `github-actions` + `docker` ecosystems (action pins, base image) |
| `justfile` | Local build / debug / restart commands (podman or docker) |

## Runtime architecture (understand before editing)

The entrypoint (`container/entrypoint.sh`) does, in order:

1. Restores `HOME` from passwd — containers run with a numeric `USER 1000`, so Docker does not set
   `HOME` (npm/uv/cargo need it).
2. Three-zone layout (the hermes-agent pattern): the image owns the whole toolchain as a system
   layer — dsh at `/opt/deepseek-harness`, uv/pnpm and the rustup proxies as real binaries
   in `/usr/local/bin`, the Rust toolchain tree in `/opt/rust`. One deliberate exception to
   read-only: rustup must write its home (`RUSTUP_HOME=/opt/rust/rustup` — settings, tmp,
   downloads, toolchains), so the build bakes `dsh` ownership into it and the entrypoint
   self-heals that ownership at every start (a recreated container would otherwise revert to
   root-owned files and the first rustup write fails). The `/home/dsh` volume holds only
   data: dsh data stays at upstream's `~/.dsh` (no `DSH_HOME` override), the process cwd is `$HOME`
   itself (dsh creates directories under it as needed), and writable caches/user-installed tools
   live under `$HOME` (`CARGO_HOME=~/.cargo`, uv data in `~/.local/share/uv`,
   `PNPM_HOME=~/.local/share/pnpm` — its executable bin is `$PNPM_HOME/bin`, and all three of
   `Containerfile`'s `ENV PATH`, `entrypoint.sh` and `dsh-web.sh` must spell that PATH identically:
   omitting `/bin` makes `pnpm add -g` refuse to install). Tool upgrades happen by image upgrade;
   a volume can never
   shadow image-provided tools. PATH is image-first (`/usr/local/bin` before `$HOME/.local/bin`)
   with user directories last. Agent high-frequency CLI tools (ripgrep, fd, python3, zip,
    openssh-client, tmux, sqlite3, vim.tiny/nano, less, rsync, wget, tree, htop, tzdata, patch,
    git-lfs, crun, plus the network/process diagnostics dig/nc/socat/traceroute/iperf3/nft, file,
    ncdu, strace, zstd/lz4, xdg-user-dirs and the dev tooling just/shellcheck) are baked into the system layer too:
    runtime `apt install` writes the
    container's writable layer and is lost on recreation, so persistent tools belong in the image,
    not in a runtime install. (deliberately absent: `tcpdump`/`iftop`/`mtr` — the container has no
    `CAP_NET_RAW`.) Toolchain copies and the npm-installed dsh that pre-source-build
    images (v0.2.x) seeded into volumes are inert (shadowed by PATH); manual cleanup
    commands live in `docs/releasing.md` § Upgrading data volumes to the image-owned
    toolchain. The entrypoint also defaults `DSH_TELEMETRY_MODE=DISABLED` (user-overridable): dsh's
    OTel feedback uploader (upstream default `FEEDBACK_ONLY` — exports the session prefix on
    explicit feedback) never uploads unless the user opts in. That switch covers the **OTel path
    only**: upstream mounts `session-log-deepseek` with `enabled: true`, so session-log suffixes
    are attached to DeepSeek API requests by default — the image leaves that upstream behavior
    alone and documents it in `docs/security.md`; do not describe the image as "no data leaves the
    container".
3. Parses `--port <N>` / `--port=<N>` (default 3080) and rejects `0` and `3081`.
4. Prepares the in-container podman runtime environment: provisions `XDG_RUNTIME_DIR`
   (`/run/user/<uid>` via passwordless sudo, `/tmp` fallback) — rootless podman cannot start
   without a writable runtime dir. The image deliberately does **not** set
   `_CONTAINERS_USERNS_CONFIGURED`: on podman 5.x that variable makes the inner podman skip
   user-namespace creation while its runtime still requires it (`euid != 0` → `needsUserns`), so
   the image store and network backend are never initialized and every store-touching command
   panics on a nil pointer (verified on 5.4.2). The inner podman therefore runs the standard
   rootless flow (`unshare` + setuid `newuidmap` over the subuid range — which requires
   `/etc/subuid`/`/etc/subgid` to carry the `dsh` range exactly **once**; duplicate lines make
   the kernel reject the overlapping mapping with `Invalid argument`, which was the original
   reason the variable was introduced). `/etc/bash.bashrc` re-exports
   `XDG_RUNTIME_DIR` for **interactive** `docker exec` shells. The host must still allow
   unprivileged (nested) user namespaces + `/dev/fuse` (+`/dev/net/tun` for rootless networking)
   and — the podman 5.x requirement — must not mask or read-only the container's `/proc`
   submounts (`--security-opt unmask=ALL` / `systempaths=unconfined`), otherwise crun cannot
   mount `/proc` inside the nested container (`mount proc: Operation not permitted`); see
   `docs/deployment.md` § In-container podman.
5. `dsh-web` then brings up the whole service stack (it is the container's supervisor — see
   `container/dsh-web.sh`): it starts `dsh web` on `127.0.0.1:$DSH_WEB_PORT` (output mirrored into
   the container log) mounted with the container-adapt plugin overlay
   (`dsh --patch /opt/dsh-container-plugin/overlay.yml --profile web ...` — the `web` alias
   rejects parent flags upstream, so the root `--profile web` form is required). The plugin
   writes the process launch token to `/tmp/dsh-caddy/launch-token` as a **state** file;
   `dsh-web` waits only for that file (bounded), generates the Caddyfile, and afterwards
   reconciles on **content change** — regenerating the Caddyfile and running `caddy reload` only
   when the token rotated — so a same-container restart never depends on a write happening (the
   old mtime handshake is what made the container wait 120 s and exit 1, i.e. a crash loop under a
   restart policy; issue #12). It starts **Caddy** on `0.0.0.0:3081`, which **preserves the browser
   `Host`/`Origin`** and forwards to dsh: no header rewrite and no cookie injection. Caddy's route
   (in order) rejects any Host outside `127.0.0.1`/`localhost`/the configured trusted authorities
   with `403` (the index token exchange itself does not apply dsh's API fence, so this is the
   proxy's job), applies optional basic auth (except `/api/remote.mux`, whose WebSocket is
   authenticated by the browser's `SameSite=Strict` session cookie), marks **both** index entries
   (`/` and `/index.html` — upstream's two supported entry paths) `Cache-Control: no-store`, marks
   the Vite-hashed `/assets/*` tree `Cache-Control: public, max-age=31536000, immutable`, and
   302s a request without a `dsh-auth-*` cookie to `/?token=...`. dsh then sets the session cookie
   and the browser holds it; the first visit is the only visible login step. The Caddyfile is
   generated at runtime into `/tmp/dsh-caddy/Caddyfile` (mode 600; it contains the launch token
   and the bcrypt hash; failure paths must not print it). Caddy restarts itself if it crashes
   (config errors still fail fast at startup); token rotation uses `caddy reload` via the
   loopback-only admin endpoint (`127.0.0.1:2019`).

   External configuration: `DSH_PUBLIC_URL` (`--public-url`, advertisement/agent context; default
   `http://127.0.0.1:3081/`) and `DSH_TRUSTED_HOST` (comma-separated extra authorities; derived
   from `DSH_PUBLIC_URL` when unset). `--public-url` is probed via `dsh --profile web --help` and
   skipped on tags that predate it. Basic auth remains `DSH_PROXY_USER` +
   `DSH_PROXY_PASSWORD` (Caddyfile `basicauth` on distro caddy 2.6 — renamed `basic_auth` upstream
   in 2.7; password bcrypt-hashed via `caddy hash-password`, fed over stdin). Setting only one auth
   variable is a startup error, not a silent no-auth fallback.
6. `dsh-web` supervises `dsh web`: if it exits or crashes it is restarted automatically. The
   browser-held session cookie survives restarts because dsh's signing secret is persisted in the
   volume; a dsh restart rotates the launch token (Caddy reload), while old browser cookies remain
   valid. The container has no browser, so `dsh-web` appends `--no-open` unless the caller already
   passed it. Inside the container, `dsh-restart` can be used to restart dsh web without restarting
   the whole container. The plugin also owns the served-side adaptations: the
   `__DSH_TRANSPORT__` row for older tags (contract item 1) and the `/container-assets/*` route
   for the extracted images; the route is registered through `ctx.effect`, and `ctx.on` owns the
   row subscription, so both dispose with the plugin.

### Hard constraints from upstream dsh (do not fight these)

- **Upstream dsh (both source tags and main) rejects `--host 0.0.0.0`** (intentional safety
  design). dsh always listens on `127.0.0.1` in this image; the Caddy proxy is the exposure
  mechanism.
- **The `/api` browser-trust fence checks HTTP headers only** (`Host`/`Origin`/`sec-fetch-site`),
  never the TCP source address. Caddy now **preserves** the browser `Host`/`Origin`; the fence is
  the real check, and external authorities are admitted only through `--trusted-host` (from
  `DSH_PUBLIC_URL`/`DSH_TRUSTED_HOST`). Caddy rejects any other Host with `403` before the request
  reaches dsh; this is necessary because the index token exchange itself does not apply the API
  fence. Upstream also requires a browser session (one-time `?token=...` login URL → signed cookie
  backed by a signing secret persisted in the volume). The plugin writes the launch token, Caddy
  redirects the first visit, and the browser holds the cookie — the **proxy is still the network
  access boundary**, but it no longer forges the session. Never present this as "secure by
  default"; `DSH_PROXY_USER`/`DSH_PROXY_PASSWORD` basic auth is the recommended control. dsh binds
  `127.0.0.1:3080` (not published), so direct access is a container-internal path, not a
  same-network-container bypass.
- **Upstream's browser code still gates the settings-document affordance on the page authority for
  older tags.** The container-adapt plugin keeps the `__DSH_TRANSPORT__ = { ownsHost: true }` row
  for those tags (rendered as an inline `<head>` script; upstream's own declaration for a shell
  that owns the Host — the desktop shell and worker-preview tunnel use it the same way). On 0.2.x
  the only `isLoopback` consumer is the settings-document controller, which `hasDocument:false`
  already hides; the row is a compatibility layer, not a security mechanism. Caddy no longer
  rewrites Host/Origin. No upstream build artifact is modified for this. (No `index.html` rewrite
  beyond that row is needed — upstream ships its own insecure-context `randomUuid()` in
  `@deepseek-ai/dsh-util-crypto`.)
- **`settings/openSettingsDocument` has no headless fallback upstream** (unlike preset/workspace
  opens, which check `canOpenPath`): the plugin keeps the button out of the UI entirely — it wraps
  the `settingsController` instance's `describe` so `settings/describe` reports
  `hasDocument: false` (upstream v0.1.7+ hardcodes `hasDocument: true` and dropped the provider's
  `documentPath`; on older tags the plugin additionally flips `documentPath`), and upstream's
  `SettingsDocumentAction` renders nothing (`status !== 'ready'`). No client code, no download
  endpoint, no `settings-controller` row override — the overlay is a single plugin include.
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
- **podman is installed for in-container rootless work, with subuid/subgid configured (the `dsh`
  range exactly once per file), plus the runtime-side preparation: `crun`, an entrypoint-provisioned
  `XDG_RUNTIME_DIR`, a `containers.conf` preset (`slirp4netns` as the rootless network command,
  `default_sysctls` emptied — Debian's `ping_group_range` default fatally fails inside nested
  rootless containers), and a `storage.conf` that spells out all four keys — `driver`,
  `graphroot`, `runroot` and `mount_program`.** Write all of them: podman applies its compiled-in
  defaults only while the file is *absent*, so once it exists a missing key becomes a failure —
  no `driver` means a warning on every single invocation, no `graphroot`/`runroot` means rootful
  podman cannot load its configuration at all (`runroot must be set`, 5.4.2). Neither is caused by
  pinning the driver; the older claim that pinning `driver` was what broke rootful was wrong
  (measured: it fails unpinned too). Rootless keeps its XDG paths regardless. Rootful *running*
  containers is still impossible here — crun needs `CAP_MKNOD`, absent from the container's
  `CapBnd`, plus cgroup-namespace handling — so that is a host-deployment decision
  (`--cap-add=MKNOD`), documented in `docs/deployment.md` but not verified end to end.
  Do **not** set `_CONTAINERS_USERNS_CONFIGURED` anywhere: on podman 5.x it makes the inner
  podman skip user-namespace creation while its runtime still needs it, and every store-touching
  command then panics on a nil pointer (item 4 above). Nested containers still depend on the host
  Docker/Podman seccomp and user-namespace settings, `/dev/fuse`, `/dev/net/tun`, and an unmasked
  `/proc` (podman 5.x: crun cannot mount proc inside the nested container otherwise) — docs must
  not promise that `podman run` always works inside this image. **Nested containers never enforce
  cgroup resource limits** (`--memory`/`--cpus` are silently ignored): cgroup v2's
  no-internal-process rule plus the container's own cgroup-namespace root (where every
  `docker exec`/healthcheck process lands) makes it impossible from inside the image. A relay
  topology (empty the ns root, move the stack into a child cgroup, enable controllers at the root,
  point podman at the relay via a `/usr/local/bin/podman` wrapper) was implemented and measured:
  limits did apply (OOM kill + `cpu.max` verified), but the kernel then rejects every process
  placement into the ns root with `EBUSY`, which breaks `docker exec` and the healthcheck — the
  change was reverted. Do not re-attempt that design; the honest limitation is documented in
  `docs/deployment.md` § In-container podman.
- **Ports**: exposed/external port is `3081`; `127.0.0.1:3080` is dsh's internal port only. Keep
  them distinct everywhere. The proxy binds `0.0.0.0:3081` because it differs from dsh's port —
  do not reintroduce container-IP binding tricks. The examples publish it on host loopback
  (`127.0.0.1:3081:3081`) — LAN/public exposure is an explicit step (the plain-LAN variant is
  documented next to the publish line).
- **Remote access is proxy-only**: Caddy is the only exposure path. Do not add host-trust
  bypasses or reintroduce Host/Origin rewriting; basic auth
  (`DSH_PROXY_USER`/`DSH_PROXY_PASSWORD`) is the access control. External authorities are named by
  `DSH_TRUSTED_HOST` or derived from `DSH_PUBLIC_URL`; Caddy's Host allowlist rejects everything
  else. DeepSeek account sign-in still requires a loopback browser origin (SSH tunnel), not a
  public hostname — do not promise otherwise.
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
just lint       # bash -n + shellcheck + doc-link/README-parity checks (no container)
just contract dsh-v0.1.2-rc.1  # static upstream-contract check for one tag
```

- The justfile passes `--format docker` only for podman (Docker has no such flag). podman needs it
  so `HEALTHCHECK` survives; GHCR images use the docker format.
- `just lint` mirrors the CI `validate` job's script and docs steps one-for-one (the same
  `tests/validate-docs.py` the workflow calls), so a lint failure is reproducible before pushing.
  It requires `shellcheck` locally and fails loudly when it is missing rather than skipping.
- Releasing: push a `dsh-v*` tag matching the upstream dsh repository tag → CI builds from
  that upstream tag, smoke-tests amd64, then publishes amd64 by digest; arm64 builds in parallel
  on GitHub's free native Arm runner (`ubuntu-24.04-arm`), and a merge job combines both into a
  multi-arch image tagged `dsh-v*` + `<sha>` + `latest`, then creates a GitHub Release with the
  same tag name. No QEMU emulation anywhere. Upstream tags are watched automatically: the
  scheduled `.github/workflows/upstream-tag.yml` opens a tracker issue when upstream publishes a
  new `dsh-v*` tag and closes it once the tag is mirrored here and its push actually triggered
  `image.yml`; on a new tag it also dispatches
  `.github/workflows/release-prep.yml`, which runs the contract check, repairs drift with a
  dsh headless agent and reviews the upstream diff for hack-simplification opportunities
  (`docs/upstream-contract.md` § Simplification triggers; see `prompts/release-prep.md`),
  re-validates with build + smoke, pushes
  the release tag, and confirms the push actually triggered `image.yml` (a fine-grained
  `RELEASE_PAT` needs the Workflows: read and write permission for that) — the manual `git tag`
  flow above remains the fallback. `.github/workflows/pat-trigger-probe.yml` can pre-verify the
  PAT's push-trigger capability on demand. `.github/dependabot.yml`
  keeps action pins and the base image updated.

## Validation checklist before committing

1. `just lint` — runs all three of: `bash -n container/*.sh tests/*.sh`,
   `shellcheck container/*.sh tests/*.sh` (must be zero output, including info-level
   diagnostics; annotate genuine false positives with a targeted `# shellcheck disable=`), and
   `python3 tests/validate-docs.py`. CI runs the same three as separate steps.
2. Examples parse: `docker compose -f examples/compose.yaml config --quiet` (or podman-compose)
3. README/README.zh parity: equal heading count, link count, and code-fence count
   (`python3 tests/validate-docs.py parity`)
4. `just --list` parses with both the podman and docker branches in mind; Docker-only hosts must
   not receive podman-only flags.
5. If you changed networking/trust behavior, verify end to end in a container: the first visit
   without a cookie must be **302** to `/?token=...` whose token matches `dsh web`'s printed
   token; following it must set an `HttpOnly; SameSite=Strict` cookie and return **200**;
   `POST /api/settings/describe` must return **200 with the cookie and 401 without it**; a
   `Host` outside the allowlist (e.g. `evil.test`) and an `Origin` that is not the request
   authority must return **403**; a trusted Host (with `DSH_TRUSTED_HOST` set) must return 200.
   With `DSH_PROXY_USER`/`DSH_PROXY_PASSWORD` set, the same flow must return **401 without basic
   credentials and succeed with them**, `/api/remote.mux` must still answer `101` with only the
   cookie, and setting only one auth variable must exit nonzero. Also start one container with
   `HTTP_PROXY`/`NODE_USE_ENV_PROXY=1` to prove the internal `--noproxy` probes still work.
   Always test inside the built image (the dev machine may lack `caddy`).
6. If you touched the container-adapt plugin (the index-injection row, the `/container-assets`
   route, the `Config` field, or one of the three build-time post-processing scripts), run
   `node tests/plugin-unit.mjs` (pure node, no image) and, in the built image, the smoke
   assertions: the served index carries the `__DSH_TRANSPORT__` row inside `<head>`, the plugin's
   own `ctx.logger` line reaches the container log, the served combined bundle inlines no image
   ≥ 100 KiB, `/container-assets/<hash>` answers with `image/*` + `immutable`, and the delivered
   build record matches the delivered artifacts. **If you change the minification profile, also
   verify a processed tree in a headless browser** (`docs/development.md` § Verifying a processed
   payload in a headless browser): the client artifacts share one script scope once dsh
   concatenates them, and renaming identifiers there breaks the boot in ways no static check
   catches.
