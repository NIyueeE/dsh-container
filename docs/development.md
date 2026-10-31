# Development

## Directory structure

```
AGENTS.md                # guidelines for agents working on this repo
Containerfile            # image build (Debian slim + node/pnpm + rust/uv + podman/crun/caddy/gh + baked agent CLI tools + source-built dsh + entrypoint)
container/
  entrypoint.sh          # entrypoint: HOME restoration, rustup-home ownership self-heal, XDG_RUNTIME_DIR provisioning, --port parsing, then exec dsh-web
  dsh-web.sh             # stack supervisor: starts dsh web with the container-adapt plugin overlay, waits for/reconciles the launch token, runs the Caddy proxy with login redirect, auto-restarts both
  dsh-restart.sh         # restart dsh web inside the container, installed as /usr/local/bin/dsh-restart
  dsh-version-floor.sh   # shared minimum-version check used by the Containerfile build
  healthcheck.sh         # container HEALTHCHECK: dsh web + Caddy expected unauthenticated statuses, installed as /usr/local/bin/healthcheck
  plugin/                # container-adapt plugin at /opt/dsh-container-plugin: host half (launch-token writer, settings-document button hide, /container-assets route), client half (built-in Plugins page card), and scripts/ (three build-time post-processing steps)
examples/
  compose.yaml           # Docker Compose example (pulls the image)
  dsh.container          # systemd Quadlet example (pulls the image)
tests/
  smoke.sh               # the heavy gate: end-to-end image test, writes smoke-diagnostic.{json,md} (also `just test`)
  plugin-unit.mjs        # container-adapt plugin contract (launch token, Config, route, logger, client card execution)
  validate-static.sh     # single-source light gate (shellcheck, plugin, docs, compose/quadlet) used by CI + publish + just lint
  validate-workflows.sh  # actionlint + zizmor in digest-pinned containers
  validate-docs.py       # doc link resolution + README/README.zh parity
  semver.mjs             # shared semver key for dsh-v* tags
  newest-tag.mjs         # semver-aware "is this the newest dsh-v* tag" helper (publish downgrade guard)
  compare-tags.mjs       # upstream-vs-this-repo newest-tag comparison for the watcher and CI
docs/
  deployment.md          # deployment & maintenance guide
  security.md            # security notes
  build.md               # build configuration & version pinning
  releasing.md           # image tags, publishing & release automation
  upstream-contract.md   # the upstream contract and its behavioral enforcement points
  development.md         # this file
justfile                 # build / debug / restart / test / lint recipes
.github/
  dependabot.yml         # Dependabot: weekly github-actions updates only (moving base image is intentional)
.github/workflows/
  ci.yml                 # light gate (static) on push/PR; heavy gate on main when the diff hits the runtime surface
  smoke.yml              # the only heavy gate: builds/pulls both architectures and runs tests/smoke.sh
  publish.yml            # tag-triggered publish: guard -> light -> build matrix (both arches by digest) -> digest refs -> smoke -> Release
  upstream-tag.yml       # 6-hourly watcher: opens the tracker issue and pushes the tag (RELEASE_PAT)
  maintenance.yml        # weekly cache + old image version cleanup
  pat-trigger-probe.yml  # on-demand verification that RELEASE_PAT's push triggers workflows
```

## Validation checklist

Run before committing (the CI runs the same checks):

```sh
just lint                     # tests/validate-static.sh --no-runtime (shellcheck, plugin, docs)
tests/validate-static.sh      # full CI static gate (adds compose/quadlet; needs docker + sudo/systemd)
just --list                    # justfile parses
```

## Verifying a processed payload in a headless browser

The three post-processing steps rewrite upstream client artifacts, and dsh serves several of them
concatenated into one response, so static checks are not enough — the payload has to boot in a real
browser. The upstream workspace already ships Playwright; run the processed tree as an **isolated
second instance** so the live one keeps serving the image's artifacts:

```sh
cp -a /opt/deepseek-harness /tmp/dsh-min                       # private copy of the install
npm install --global --prefix /tmp/dsh-build-tools esbuild@0.25.12
node /opt/dsh-container-plugin/scripts/extract-inline-assets.js --root /tmp/dsh-min
node /opt/dsh-container-plugin/scripts/minify-client.mjs --root /tmp/dsh-min \
  --esbuild /tmp/dsh-build-tools/bin/esbuild
node --disable-warning=ExperimentalWarning --experimental-strip-types \
  /opt/dsh-container-plugin/scripts/refresh-build-record.mjs /tmp/dsh-min

# isolated instance from the copy: own HOME/DSH_HOME, own launch-token dir via the overlay's
# `config.runtimeDir` (see container/plugin/overlay.yml) — never the live /tmp/dsh-caddy
node /tmp/dsh-min/apps/cli/lib/bin.js --patch /tmp/min-overlay.yml --profile web \
  --port 3092 --no-open

# browser: the vendored Playwright, then follow the instance's launch-token redirect / drive the page
node /opt/deepseek-harness/node_modules/.pnpm/playwright@1.61.1/node_modules/playwright/cli.js \
  install --with-deps chromium
```

What must hold on the processed tree: zero console/page errors, **every** `__DSH_BOOT__.entries`
entry activated (a partial boot logs `web boot: N entries did not activate`), the settings panel
opening (the plugin hides the document button; no `__DSH_TRANSPORT__` row is injected), and the
extracted `/container-assets/*.png` files fetching and decoding. A payload can pass `node --check` and the
loader-registration self-check and still fail here: identifier-renaming minification did exactly
that (58 of 65 entries failed, because concatenated artifacts share one script scope and renamed
helpers collide across files — see `container/plugin/scripts/minify-client.mjs`).

## CI lanes

Two gates, defined once each and reused everywhere:

- **light** (`ci.yml` / `light`) — `tests/validate-static.sh` + `tests/validate-workflows.sh`.
  Runs on every push to `main`, every pull request, and as part of every publish. It never builds
  an image.
- **heavy** (`smoke.yml`) — builds or pulls both architectures and runs `tests/smoke.sh` on each.
  Runs on `main` pushes only when the diff touches the runtime surface (`Containerfile`,
  `container/**`, `tests/smoke.sh`, `.github/workflows/smoke.yml`), and on every publish. A diff
  that cannot be computed forces the heavy gate; PRs never run it. The workflow validates that the
  two image inputs are both empty (build) or both immutable `@sha256:` references (pull) before any
  runner starts building; there is no single-architecture mode.

All workflows pin `ubuntu-24.04` (arm64: `ubuntu-24.04-arm`) instead of `ubuntu-latest`, so a
release gate cannot change operating system under an in-flight release while GitHub migrates the
`ubuntu-latest` label.
