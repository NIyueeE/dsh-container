# Build Configuration & Version Policy

The base image is the moving `debian:13-slim` tag, Node.js floats within 24.x, the Rust channel is
`stable`, uv defaults to `latest`, `yq` is installed with an unversioned `uv tool install`, and the
apt packages carry no `=version` (Caddy, podman, crun, gh included). That is a decision: the
in-image toolchain is allowed to drift because users consume one immutable manifest digest, not a
build recipe. See [Toolchain versions float by design](#toolchain-versions-float-by-design).

What is pinned is the source: dsh is built from the official repository at the upstream tag the
image is released for, with its `pnpm-lock.yaml`, and pnpm is installed at the version that tag's
`packageManager` field requires. uv, pnpm and the rustup proxies are image-owned real binaries in
the system layer (`/usr/local/bin`, `/opt/rust`; the one writable exception is rustup's home
`/opt/rust/rustup`, which rustup must write at runtime; it is built `dsh`-owned and the entrypoint
repairs its ownership on every start), so tool versions are a property of the image tag, not of the
volume. Caddy/podman/gh come from apt.

Alongside the toolchain, the image bakes an agent's high-frequency CLI tools into the system layer
(`ripgrep`, `fd`, `python3`, `zip`, `openssh-client`, `tmux`, `sqlite3`, `vim.tiny`, `nano`,
`less`, `rsync`, `wget`, `tree`, `htop`, `tzdata`, `patch`, `git-lfs`, plus `crun` for nested
rootless podman, and a diagnostics set: `dig`/`nc`/`socat`/`traceroute`/`iperf3`/`nft`, `file`, `ncdu`,
`strace`, `zstd`/`lz4`, `bc`, `moreutils`, `pv`, `uuid-runtime`). Runtime `apt install` writes the
container's writable layer and is lost on
container recreation, so anything that must persist is installed at build time (or added via a
child image). `rustfmt`/`clippy` are installed next to the minimal Rust profile for the same
reason; `yq` is installed with `uv tool install` into `/opt/uv-tools` (see
[deployment.md](deployment.md#installing-tools-that-persist) for why it is the Python `yq`). The
full rationale and the persistence matrix live in
[deployment.md](deployment.md) § Built-in tools.

## Toolchain versions float by design

Exactly four things in the build are pinned, and none of them exist to make rebuilds bit-identical:

| Pin | Why it stays |
|---|---|
| `DSH_TAG` | release identity: image tag, Release page, and built dsh source always name the same upstream tag; pnpm and the dependency tree follow from it (`packageManager`, `pnpm-lock.yaml`) |
| `esbuild@0.25.12` | the client bundles are minified in place and their `.dsh-build` record is recomputed, so a minifier bump changes a tested build product |
| action commit SHAs | supply-chain hardening for the workflows (Dependabot maintains them) |
| actionlint/zizmor image digests | the same, for the static gates |

Everything else follows whatever upstream ships at build time. This is safe because users consume
one immutable digest, not a recipe: that digest is built once, smoke-tested by the heavy gate (which
runs against exactly the digests that get merged), and stamped with the versions it actually
contains in `/etc/dsh-container/provenance.json`. A toolchain bump can therefore only change the
*next* build. If it breaks behaviour, the heavy gate refuses to publish. Pinning every version
would buy rebuild determinism that nobody consumes, at the cost of a permanent bump treadmill (and
Dependabot cannot even see the base image behind `ARG`).

The trade-off: rebuilds are **not** bit-identical. Re-running a publish for the
newest tag rebuilds from scratch, so the same tag can end up pointing at a newer digest with newer
tools ([releasing.md](releasing.md)). `BASE_IMAGE`, `RUST_TOOLCHAIN` and `UV_VERSION` exist for
one-off forensic rebuilds; they are not CI maintenance surface.

## Build arguments

All arguments are optional. The defaults are the intended production configuration; the version
arguments are escape hatches, not a pinning duty (see above).

| Build arg | Default | Description |
|---|---|---|
| `BASE_IMAGE` | `debian:13-slim` | Base image (moving tag; the build intentionally follows the current `13-slim`). Override only if you also adjust the `/home/dsh` user-layer assumptions |
| `DSH_TAG` | `latest` | Upstream dsh git tag to build (`latest` resolves the newest upstream `dsh-v*` tag at build time); minimum supported tag is `dsh-v0.2.1-alpha.3` (alpha.1/alpha.2 still gate settings persistence on the page authority), and lower tags fail the build. The image is immutable at runtime; there is no in-container dsh auto-update |
| `BUILD_VERSION` | `latest` | Written to the OCI label `org.opencontainers.image.version`; CI passes the upstream dsh tag on `dsh-v*` tag builds (see [releasing.md](releasing.md)) |
| `RUST_TOOLCHAIN` | `stable` | Rust toolchain (latest stable at build time; pass a version for a one-off rebuild) |
| `UV_VERSION` | `latest` | uv version installed by the official standalone installer script (`latest` resolves the newest release at build time; pass a version for a one-off rebuild) |
| `BUILD_GIT_SHA` / `BUILD_GIT_REF` | `unknown` | Written to the OCI labels `org.opencontainers.image.revision` / `org.opencontainers.image.ref.name` |

Toolchain vs. data: the image owns the tools (read-only at runtime; the one exception is rustup's
home `/opt/rust/rustup`, which rustup must write: it is built `dsh`-owned and self-healed by the
entrypoint), the volume owns the state.

- Image-owned: uv/uvx and the pnpm binary in `/usr/local/bin`, the Rust toolchain tree in
  `/opt/rust` (rustup proxies symlinked into `/usr/local/bin`), dsh in `/opt/deepseek-harness`,
  and `yq`'s `uv tool` virtualenv in `/opt/uv-tools` (shims in `/usr/local/bin`).
  Tool upgrades happen by image upgrade. `uv self update` cannot write the root-owned
  `/usr/local/bin`, a runtime `rustup update` would only write the container layer (lost on
  recreation), and `uv tool upgrade yq` fails against the root-owned `/opt/uv-tools` by design,
  so runtime updates are not a supported upgrade path.
- Volume-owned (writable, persisted): `~/.cargo` (cargo registry/cache and `cargo install`
  binaries), uv data in `~/.local/share/uv` and `~/.cache/uv`, pnpm store and user global
  packages in `~/.local/share/pnpm` (`PNPM_HOME`) with their executables in `$PNPM_HOME/bin`,
  anything the user puts in `~/.local/bin`. All of those bin directories are on PATH.
  User-installed tools sit last on PATH and can never shadow image-provided ones.
- Custom Rust toolchains: override `RUSTUP_HOME` to a volume directory and run `rustup-init`
  there (advanced escape hatch; the image-managed toolchain is unaffected).

dsh itself is built into the system layer at `/opt/deepseek-harness` (source tree, `node_modules`,
and built client/web artifacts). It is replaced on image upgrades and is independent of the
persisted home volume, so a fresh or empty `/home/dsh` volume never hides `dsh`.

The final image keeps a refreshed apt package index: `apt-get update` runs once more at the end of
the build and `/var/lib/apt/lists` is preserved, so `apt install` works inside the container without
a manual update first (the index lives in the system layer and resets on image upgrades). Note that
the preserved index is a build-time snapshot: as the image ages, installs can start failing with
404s or hash mismatches. Run `sudo apt-get update` inside the container and retry when that
happens.

Older images seeded toolchain copies into the volume (`~/.local/bin` uv/uvx, the pnpm prefix under
`~/.local/share/pnpm`, rustup proxies in `~/.cargo/bin`). Those are inert, because PATH prefers the
image-owned binaries and they can never shadow them, but they waste space; remove them manually to
reclaim `~/.rustup`'s ~1GB. The commands live in
[releasing.md](releasing.md) § Upgrading data volumes to the image-owned toolchain.

The image post-processes the client artifacts after `pnpm run build:official`, inside the build
layer: they live in the system layer and reset on image upgrades, so they must be regenerated on
every build. Large inline images are extracted to files served by the container-adapt plugin
(`/container-assets/*`), the client bundles are minified with a pinned esbuild, and the upstream
`.dsh-build` client build record is refreshed afterwards so it keeps matching the delivered
artifacts. All three steps are fail-fast; see `container/plugin/scripts/`.

The upstream `build:official` native gate compiles only the Node-API addon
(`build:native-system --host-addon-only`). The image also runs the full `native/system` build with
the `musl-tools` toolchain so the static-musl `landlock-run` launcher ships in the image: `dsh`'s
`workspace-write` sandbox needs `bwrap` or that launcher, and the image deliberately does not
install `bwrap` (unprivileged user namespaces are unreliable inside containers). `tests/smoke.sh`
probes the launcher (`landlock-run --probe`) rather than only checking that the file exists.

## Example

With podman, keep `--format docker` so the `HEALTHCHECK` survives (podman's default OCI format
drops it):

```bash
podman build --format docker \
             --build-arg DSH_TAG=dsh-v0.2.1-rc.2 \
             --build-arg RUST_TOOLCHAIN=1.88.0 \
             -t dsh-container .
```

The resulting image stays on that upstream tag until the next image release.
