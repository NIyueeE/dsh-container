# Build Configuration & Version Pinning

Every mutable component in the image (base image / dsh / rust / uv) can be pinned with
`--build-arg`; CI passes git info plus the release version and uses defaults for everything else.

## Build arguments

| Build arg | Default | Description |
|---|---|---|
| `BASE_IMAGE` | `universal:latest` | Base image (currently same digest as `6.1.1-noble`; pin an exact tag for reproducibility) |
| `DSH_VERSION` | `latest` | dsh version; when pinned, consider `DSH_AUTO_UPDATE=0` at runtime |
| `BUILD_VERSION` | `latest` | Written to the OCI label `org.opencontainers.image.version`; CI passes the release version on `v*` tag builds (see [releasing.md](releasing.md)) |
| `RUST_TOOLCHAIN` | `stable` | Rust toolchain (e.g. `1.88.0`) |
| `UV_VERSION` | `0.12.3` | uv version (COPYed from the official image, no install script) |
| `BUILD_GIT_SHA` / `BUILD_GIT_REF` | `unknown` | Written to OCI labels (`org.opencontainers.image.*`) |

## Example

The idea mirrors Claude Code's `DISABLE_AUTOUPDATER=1`: pin the version and turn off the runtime
auto-update.

```bash
podman build --build-arg DSH_VERSION=0.1.0-rc.6 \
             --build-arg RUST_TOOLCHAIN=1.88.0 \
             --build-arg UV_VERSION=0.12.3 \
             -t dsh-container .
# at runtime: DSH_AUTO_UPDATE=0
```
