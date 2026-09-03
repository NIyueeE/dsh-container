# Build Configuration & Version Pinning

The base image is pinned by default, and the dsh source tag / Rust toolchain / uv version can be
pinned with `--build-arg`. uv is installed by the official standalone installer script (the same
pattern as rustup; `UV_VERSION` pins it, `latest` resolves the newest release at build time); pnpm
is installed at the version required by the checked-out dsh tag (read from its `packageManager`
field). All three are image-owned real binaries in the read-only system layer (`/usr/local/bin`,
`/opt/rust`), so tool versions are a property of the image tag, not of the volume. Caddy/podman/gh
come from apt; dsh is built from the official repository with its `pnpm-lock.yaml`. Default builds
are therefore reproducible at the level of the upstream lockfile; pin `DSH_TAG` for a fully pinned
dsh version.

## Build arguments

| Build arg | Default | Description |
|---|---|---|
| `BASE_IMAGE` | `debian:13-slim` | Base image (pinned for reproducible builds; override only if you also adjust the `/home/dsh` user-layer assumptions) |
| `DSH_TAG` | `latest` | Upstream dsh git tag to build (`latest` resolves the newest upstream `dsh-v*` tag at build time). The image is immutable at runtime — there is no in-container dsh auto-update |
| `BUILD_VERSION` | `latest` | Written to the OCI label `org.opencontainers.image.version`; CI passes the upstream dsh tag on `dsh-v*` tag builds (see [releasing.md](releasing.md)) |
| `RUST_TOOLCHAIN` | `stable` | Rust toolchain (e.g. `1.88.0`) |
| `UV_VERSION` | `latest` | uv version installed by the official standalone installer script (`latest` resolves the newest uv release at build time) |
| `BUILD_GIT_SHA` / `BUILD_GIT_REF` | `unknown` | Written to the OCI labels `org.opencontainers.image.revision` / `org.opencontainers.image.ref.name` |

Toolchain vs. data: the image owns the tools (read-only at runtime), the volume owns the state.

- Image-owned: uv/uvx and the pnpm binary in `/usr/local/bin`, the Rust toolchain tree in
  `/opt/rust` (rustup proxies symlinked into `/usr/local/bin`), dsh in `/opt/deepseek-harness`.
  Tool upgrades happen by image upgrade — `rustup update` / `uv self update` are intentionally
  not usable at runtime.
- Volume-owned (writable, persisted): `~/.cargo` (cargo registry/cache and `cargo install`
  binaries), uv data in `~/.local/share/uv` and `~/.cache/uv`, pnpm store and user global
  packages in `~/.local/share/pnpm` (`PNPM_HOME`), anything the user puts in `~/.local/bin`.
  User-installed tools sit last on PATH and can never shadow image-provided ones.
- Custom Rust toolchains: override `RUSTUP_HOME` to a volume directory and run `rustup-init`
  there (advanced escape hatch; the image-managed toolchain is unaffected).

dsh itself is built into the system layer at `/opt/deepseek-harness` (source tree, `node_modules`,
and built client/web artifacts). It is replaced on image upgrades and is independent of the
persisted home volume, so a fresh or empty `/home/dsh` volume never hides `dsh`.

The final image keeps a refreshed apt package index: `apt-get update` runs once more at the end of
the build and `/var/lib/apt/lists` is preserved, so `apt install` works inside the container without
a manual update first (the index lives in the system layer and resets on image upgrades).

Older images seeded toolchain copies into the volume (`~/.local/bin` uv/uvx, the pnpm prefix under
`~/.local/share/pnpm`, rustup proxies in `~/.cargo/bin`). Those are inert — PATH prefers the
image-owned binaries and they can never shadow them — but waste space; remove them manually to
reclaim `~/.rustup`'s ~1GB. The commands ship in each release note (see also
[releasing.md](releasing.md)).

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
