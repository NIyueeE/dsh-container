# Build Configuration & Version Pinning

The base image is pinned by default, and the dsh top-level version / Rust toolchain can be pinned
with `--build-arg`. uv is copied from a pinned `ghcr.io/astral-sh/uv` image; pnpm is installed with
npm at build time (latest release), then both live in the persisted user layer. Caddy/podman/gh come
from apt; the npm dependency tree of `@deepseek-ai/dsh` has no lockfile. Default builds are
therefore not byte-for-byte reproducible.

## Build arguments

| Build arg | Default | Description |
|---|---|---|
| `BASE_IMAGE` | `debian:13-slim` | Base image (pinned for reproducible builds; override only if you also adjust the `/home/dsh` user-layer assumptions) |
| `DSH_VERSION` | `latest` | dsh version; auto-update is off by default, so a pinned image stays pinned unless you set `DSH_AUTO_UPDATE=1` at runtime |
| `BUILD_VERSION` | `latest` | Written to the OCI label `org.opencontainers.image.version`; CI passes the release version on `v*` tag builds (see [releasing.md](releasing.md)) |
| `RUST_TOOLCHAIN` | `stable` | Rust toolchain (e.g. `1.88.0`) |
| `BUILD_GIT_SHA` / `BUILD_GIT_REF` | `unknown` | Written to the OCI labels `org.opencontainers.image.revision` / `org.opencontainers.image.ref.name` |

User-level tool defaults live under the persisted `/home/dsh` volume:

- Rust/cargo: `~/.rustup` and `~/.cargo`
- uv: `~/.local/bin`, with uv's default `~/.local/share/uv` and `~/.cache/uv`
- pnpm: `~/.local/share/pnpm`, binary linked from `~/.local/bin/pnpm`
- dsh: npm global prefix `~/.local` (`NPM_CONFIG_PREFIX=/home/dsh/.local`), binary linked from
  `~/.local/bin/dsh`

These tools are copied into the volume when it is first created; after that the volume owns them,
so a newer image does not overwrite an existing user's tools. Update them inside the container
(`rustup update`, `uv self update`, `pnpm add -g pnpm`, `dsh-update`) or recreate the volume.

The image's `dsh-client-patch` compatibility layer is intentionally applied at runtime before every
`dsh web` start rather than baked into the user layer: existing persistent volumes and dsh
auto-updates therefore receive the patch too, and it can skip gracefully if upstream changes the
bundle strings.

## Example

The idea mirrors Claude Code's `DISABLE_AUTOUPDATER=1`: pin the version and leave runtime
auto-update off. With podman, keep `--format docker` so the `HEALTHCHECK` survives (podman's
default OCI format drops it):

```bash
podman build --format docker \
             --build-arg DSH_VERSION=0.1.0-rc.6 \
             --build-arg RUST_TOOLCHAIN=1.88.0 \
             -t dsh-container .
# DSH_AUTO_UPDATE is already 0 by default, so this image stays on 0.1.0-rc.6
```
