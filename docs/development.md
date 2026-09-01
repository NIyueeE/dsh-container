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
examples/
  compose.yaml           # Docker Compose example (pulls the image)
  dsh.container          # systemd Quadlet example (pulls the image)
docs/
  deployment.md          # deployment & maintenance guide
  security.md            # security notes
  build.md               # build configuration & version pinning
  releasing.md           # image tags & publishing
  design.md              # design references
  development.md         # this file
.github/workflows/
  image.yml              # build + validate image; publish + GitHub Release on dsh-v* tags
```

## Local development

```sh
just build       # build ghcr.io/niyueee/dsh-container:local locally (podman or docker)
just debug       # run in the foreground (bridge networking, port 3081 published)
just restart-dsh # restart dsh web inside the running "dsh" container without restarting it
```
