# Development

## Directory structure

```
AGENTS.md                # guidelines for agents working on this repo
Containerfile            # image build (Debian slim + node/pnpm + rust/uv + podman/caddy/gh + source-built dsh + entrypoint)
container/
  entrypoint.sh          # container entrypoint: Caddy proxy + start dsh-web
  dsh-web.sh             # dsh web supervisor: auto-restart dsh web, installed as /usr/local/bin/dsh-web
  dsh-restart.sh         # restart dsh web inside the container, installed as /usr/local/bin/dsh-restart
  dsh-client-patch.sh    # idempotent frontend compatibility patch, installed as /usr/local/bin/dsh-client-patch
  dsh-migrate-legacy.sh  # removes legacy npm-installed dsh from old data volumes on boot
examples/
  compose.yaml           # Docker Compose example (pulls the image)
  dsh.container          # systemd Quadlet example (pulls the image)
tests/
  smoke.sh               # end-to-end image smoke test (CI + `just test`)
  contract.sh            # static upstream-contract check against a dsh-v* tag
prompts/
  release-prep.md        # system prompt for the headless codex release agent
docs/
  deployment.md          # deployment & maintenance guide
  security.md            # security notes
  build.md               # build configuration & version pinning
  releasing.md           # image tags, publishing & release automation
  upstream-contract.md   # the upstream contract (machine-checked by tests/contract.sh)
  design.md              # design references
  development.md         # this file
justfile                 # build / debug / restart / test / contract recipes
.github/
  dependabot.yml         # Dependabot: weekly github-actions + docker (base image) updates
.github/workflows/
  image.yml              # build + validate image; publish + GitHub Release on dsh-v* tags
  upstream-tag.yml       # daily watcher: tracks upstream dsh tags, dispatches release-prep
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
