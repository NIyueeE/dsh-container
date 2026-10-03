# Development

## Directory structure

```
AGENTS.md                # guidelines for agents working on this repo
Containerfile            # image build (Debian slim + node/pnpm + rust/uv + podman/crun/caddy/gh + baked agent CLI tools + source-built dsh + entrypoint)
container/
  entrypoint.sh          # entrypoint: HOME restoration, rustup-home ownership self-heal, XDG_RUNTIME_DIR provisioning, --port parsing, then exec dsh-web
  dsh-web.sh             # stack supervisor: starts dsh web with the container-adapt plugin overlay, waits for/reconciles the session cookie, runs the Caddy proxy, auto-restarts both
  dsh-restart.sh         # restart dsh web inside the container, installed as /usr/local/bin/dsh-restart
  healthcheck.sh         # container HEALTHCHECK: dsh web + Caddy reachability, installed as /usr/local/bin/healthcheck
  plugin/                # container-adapt plugin at /opt/dsh-container-plugin: cookie bootstrap, settings-document button hide, __DSH_TRANSPORT__ index injection, /container-assets route; scripts/ holds the three build-time post-processing steps (extract inline images, esbuild minify, build-record refresh)
examples/
  compose.yaml           # Docker Compose example (pulls the image)
  dsh.container          # systemd Quadlet example (pulls the image)
tests/
  smoke.sh               # end-to-end image smoke test (CI + `just test`)
  contract.sh            # static upstream-contract check against a dsh-v* tag
  triage-diff.sh         # code-level agent admission gate for release-prep (diff triage)
  plugin-unit.mjs        # container-adapt plugin contract (injection row, Config, route, logger)
prompts/
  release-prep.md        # system prompt for the headless dsh release agent
docs/
  deployment.md          # deployment & maintenance guide
  security.md            # security notes
  build.md               # build configuration & version pinning
  releasing.md           # image tags, publishing & release automation
  upstream-contract.md   # the upstream contract (machine-checked by tests/contract.sh)
  development.md         # this file
justfile                 # build / debug / restart / test / contract recipes
.github/
  dependabot.yml         # Dependabot: weekly github-actions + docker (base image) updates
.github/workflows/
  image.yml              # build + validate image; contract gate + publish + composed GitHub Release on dsh-v* tags
  upstream-tag.yml       # daily watcher: tracks upstream dsh tags, dispatches release-prep, flags an unpublished tag
  release-prep.yml       # automated release preparation: contract -> agent -> verify -> tag
```

## Validation checklist

Run before committing (the CI runs the same checks):

```sh
bash -n container/*.sh tests/*.sh                     # shell syntax
docker compose -f examples/compose.yaml config --quiet
just --list                                           # justfile parses
python3 - <<'PY'                                      # README parity
from pathlib import Path
import re
en = Path('README.md').read_text(); zh = Path('README.zh.md').read_text()
h = lambda t: len(re.findall(r'^#{1,6} .*$', t, re.M))
l = lambda t: len(re.findall(r'\[[^\]]*\]\([^)]*\)', t))
assert h(en) == h(zh) and l(en) == l(zh) and en.count('```') == zh.count('```')
print('README parity OK')
PY
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

# isolated instance from the copy: own HOME/DSH_HOME, own cookie dir via the overlay's
# `config.runtimeDir` (see container/plugin/overlay.yml) — never the live /tmp/dsh-caddy
node /tmp/dsh-min/apps/cli/lib/bin.js --patch /tmp/min-overlay.yml --profile web \
  --port 3092 --no-open

# browser: the vendored Playwright, then drive the page with the instance's session cookie
node /opt/deepseek-harness/node_modules/.pnpm/playwright@1.61.1/node_modules/playwright/cli.js \
  install --with-deps chromium
```

What must hold on the processed tree: zero console/page errors, **every** `__DSH_BOOT__.entries`
entry activated (a partial boot logs `web boot: N entries did not activate`), the settings panel
opening (that path depends on the injected `__DSH_TRANSPORT__` row), and the extracted
`/container-assets/*.png` files fetching and decoding. A payload can pass `node --check` and the
loader-registration self-check and still fail here: identifier-renaming minification did exactly
that (58 of 65 entries failed, because concatenated artifacts share one script scope and renamed
helpers collide across files — see `container/plugin/scripts/minify-client.mjs`).

## CI lanes

`image.yml` classifies every push and pull request from its **real diff**:

- **docs-only** (`*.md` or `LICENSE` touched, nothing else): the image build + smoke test are
  skipped and only the validation job runs (plus a relative-link check over the docs). Tag builds
  never take this lane, and anything undecidable (new branch, force push, shallow clone, manual
  dispatch) falls back to the full build — the classifier fails closed.
- **everything else** (code, examples, workflows, Containerfile, …): full build + smoke, exactly
  as before.
