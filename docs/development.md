# Development

## Directory structure

```
Containerfile            # image build (base image + rustup/uv + dsh + entrypoint)
container/
  entrypoint.sh          # container entrypoint: auto-update + start dsh web
  dsh-update.sh          # dsh update script (idempotent, runnable standalone)
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
  image.yml              # build + validate image; publish + GitHub Release on v* tags
```

## Local development

```sh
just build   # build ghcr.io/niyueee/dsh-container:local locally
just debug   # run in the foreground (bridge networking, port 3081 published)
```
