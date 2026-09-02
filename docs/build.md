# Build Configuration & Version Pinning

The base image is pinned by default, and the dsh source tag / Rust toolchain can be pinned with
`--build-arg`. uv is copied from a pinned `ghcr.io/astral-sh/uv` image; pnpm is installed at the
version required by the checked-out dsh tag (read from its `packageManager` field), then both live
in the persisted user layer. Caddy/podman/gh come from apt; dsh is built from the official
repository with its `pnpm-lock.yaml`. Default builds are therefore reproducible at the level of
the upstream lockfile; pin `DSH_TAG` for a fully pinned dsh version.

## Build arguments

| Build arg | Default | Description |
|---|---|---|
| `BASE_IMAGE` | `debian:13-slim` | Base image (pinned for reproducible builds; override only if you also adjust the `/home/dsh` user-layer assumptions) |
| `DSH_TAG` | `latest` | Upstream dsh git tag to build (`latest` resolves the newest upstream `dsh-v*` tag at build time). The image is immutable at runtime — there is no in-container dsh auto-update |
| `BUILD_VERSION` | `latest` | Written to the OCI label `org.opencontainers.image.version`; CI passes the upstream dsh tag on `dsh-v*` tag builds (see [releasing.md](releasing.md)) |
| `RUST_TOOLCHAIN` | `stable` | Rust toolchain (e.g. `1.88.0`) |
| `BUILD_GIT_SHA` / `BUILD_GIT_REF` | `unknown` | Written to the OCI labels `org.opencontainers.image.revision` / `org.opencontainers.image.ref.name` |

User-level tool defaults live under the persisted `/home/dsh` volume:

- Rust/cargo: `~/.rustup` and `~/.cargo`
- uv: `~/.local/bin`, with uv's default `~/.local/share/uv` and `~/.cache/uv`
- pnpm: `~/.local/share/pnpm`, binary linked from `~/.local/bin/pnpm`

dsh itself is built into the system layer at `/opt/deepseek-harness` (source tree, `node_modules`,
and built client/web artifacts). It is replaced on image upgrades and is independent of the
persisted home volume, so a fresh or empty `/home/dsh` volume never hides `dsh`.

The user-level tools are copied into the volume when it is first created; after that the volume owns
them, so a newer image does not overwrite an existing user's tools. Update them inside the container
(`rustup update`, `uv self update`, `pnpm add -g pnpm`) or recreate the volume.

The image's `dsh-client-patch` compatibility layer is intentionally applied at runtime before every
`dsh web` start rather than baked into the user layer: the patch target lives in the system layer
and resets on image upgrades, so it must be reapplied on every boot. It skips gracefully if
upstream changes the bundle strings.

## Example

With podman, keep `--format docker` so the `HEALTHCHECK` survives (podman's default OCI format
drops it):

```bash
podman build --format docker \
             --build-arg DSH_TAG=dsh-v0.1.2-alpha.4 \
             --build-arg RUST_TOOLCHAIN=1.88.0 \
             -t dsh-container .
```

The resulting image stays on that upstream tag until the next image release.
