# Image Tags & Publishing

## Image tags

Each release pushes one multi-platform image (Linux `amd64` + `arm64`) with three tags:

| Tag | Source | Description |
|---|---|---|
| `dsh-v*` (e.g. `dsh-v0.1.2-alpha.4`) | upstream dsh tags | the release artifact; image tag, release page tag, and built dsh source tag are all the same upstream tag |
| `latest` | newest `dsh-v*` release | points to the most recent release; what the examples pull |
| `<commit-sha>` | release builds | exactly reproducible |

The version tag keeps the full `dsh-` prefix and is not published as a bare `v*` tag, so it never
collides with older container-image tags such as `v0.2.2`.

## CI release workflow

Pushing to GitHub triggers [`.github/workflows/image.yml`](../.github/workflows/image.yml):

- **main / PR / manual dispatch**: build (amd64) + smoke test a temporary image only — **nothing is pushed
  to GHCR**. CI validates that the image is usable, nothing more.
- **`dsh-v*` tag (release)**: the workflow checks out the matching upstream
  `deepseek-ai/deepseek-harness` tag (`DSH_TAG=<tag>`), builds and smoke-tests the amd64 image, and
  only after the smoke test passes publishes it by digest. In parallel, the arm64 image is built on
  GitHub's free native Arm runner (`ubuntu-24.04-arm`) — no QEMU emulation. Once both platform
  digests exist, a merge job combines them into one multi-arch image and applies
  `dsh-v*` + `<sha>` + `latest`. A broken image never gets a tag; the release is not created if
  build or smoke fails.

### Tag alignment

For a tag build, one version string flows through the whole release:

- upstream dsh tag `dsh-v0.1.2-alpha.4` → release page `dsh-v0.1.2-alpha.4` → image tag
  `ghcr.io/niyueee/dsh-container:dsh-v0.1.2-alpha.4`
- `Containerfile` checks out that same tag before `pnpm install` / `pnpm run build:official`
- OCI label `org.opencontainers.image.version` = `dsh-v0.1.2-alpha.4`, via the `BUILD_VERSION`
  build arg (`latest` for non-release builds, which are never published)

Releases are created by pushing the matching tag to this repository (the automated
release-preparation pipeline below does this automatically; the commands remain the manual
fallback):

```bash
git tag dsh-v0.1.2-alpha.4
git push origin dsh-v0.1.2-alpha.4
```

For local/manual builds, pin directly with `--build-arg DSH_TAG=dsh-v0.1.2-alpha.4` (see
[build.md](build.md)).

## Tracking upstream releases

There is no version pin in this repository to bump: a release exists as soon as the matching
upstream tag is pushed here. Two automated helpers keep the repository in sync with upstream:

### Upstream tag watcher (`.github/workflows/upstream-tag.yml`)

Dependabot cannot watch another repository's git tags, so a small scheduled workflow does it.
Running daily (plus on every `dsh-v*` tag push and on manual dispatch), it compares the newest
`dsh-v*` tag of `deepseek-ai/deepseek-harness` with the newest `dsh-v*` tag of this repository
(semver-aware, so a stable tag outranks its pre-releases: `dsh-v0.1.2-alpha.5` < `dsh-v0.1.2`):

- **upstream ahead** → opens one issue ("New upstream dsh release available: …") with the release
  notes link, the upstream diff, and the manual `git tag` / `git push` commands (kept as the
  fallback path); an older tracker issue is closed first so at most one stays open. It then fires a
  `repository_dispatch` that starts the automated release-preparation pipeline below;
- **tags equal** → any open tracker issue is closed automatically.

The upstream repository can be overridden with the `DSH_UPSTREAM_REPO` repository variable
(default `deepseek-ai/deepseek-harness`), mirroring `vars.DSH_TAG` in `image.yml`. To re-check on
demand, run "Upstream dsh tag watch" → "Run workflow" from the Actions tab.

### Automated release preparation (`.github/workflows/release-prep.yml`)

When the watcher finds a new upstream tag it dispatches the release-prep pipeline, which removes
the manual `git tag` step in the common case:

```text
upstream tag ─▶ watcher ─▶ contract ─┬─ clean ──▶ verify ───────────────┐
                                     └─ drift ──▶ prep (codex agent) ──┤
                                                  pushes repair branch │ green
                                                                       ▼
                             release: downgrade guard ─▶ PAT tag push ─▶ close issue
                                                                       │ push event
                                                                       ▼
                             image.yml: multi-arch build ─▶ GHCR + GitHub Release
```

1. **contract** — `tests/contract.sh` statically checks the upstream tag against
   [upstream-contract.md](upstream-contract.md) (patch anchors, CLI flags, request fence) in
   seconds, before any image is built. If this repository already has the tag, the run skips
   (repeated and manual dispatches are idempotent).
2. **prep** (only on drift) — a headless [codex](https://github.com/openai/codex) agent (version
   pinned in the workflow) runs in the `codex-universal` container, reviews the pre-fetched
   upstream diff and checkout against the contract, and applies a minimal repair (typically new
   candidate strings in `dsh-client-patch.sh`); drift in security-defining contract items is
   reported, never worked around. It pushes a `release-prep/<tag>` branch and posts its report to
   the tracker issue. The agent works fully offline (network is not part of its sandbox).
3. **verify** — checks out the repair branch (if any), builds the image from the new upstream tag
   (`DSH_TAG=<tag>`, same Containerfile as the release) and runs `tests/smoke.sh`. The agent's own
   claims are never trusted; CI decides.
4. **release** — a downgrade guard first refuses any tag that is not semver-newer than the newest
   `dsh-v*` tag already in this repository (so mis-dispatched old tags cannot pull `latest`
   backwards). Then the repair branch is fast-forwarded to `main` (if any) and the `dsh-v*` tag is
   pushed with the `RELEASE_PAT` secret, closing the tracker issue.
5. **publish** — the PAT push triggers `image.yml` (described above), which re-runs the same smoke
   suite as the final gate before publishing the multi-arch image and creating the GitHub Release.
6. **notify** — if any stage fails, a failure note with per-job results and a link to the run is
   posted to the tracker issue, which stays open for manual follow-up. A failed pipeline never
   publishes anything.

The release is validated end to end (contract → smoke) before the tag is pushed; `image.yml`
re-runs the same smoke suite as the final gate.

#### Why the final tag push needs a user PAT

Push-event workflows do not run for every credential — this was verified live during the first
automated release:

- `GITHUB_TOKEN` — events it creates never trigger workflows (GitHub's anti-recursion rule);
- a GitHub App installation token — its pushes also do not trigger push-event workflows (the tag
  landed, zero runs started);
- `repository_dispatch` / `workflow_dispatch` created by `GITHUB_TOKEN` **are** explicitly exempt —
  that is how the watcher starts this pipeline with no extra credentials.

So the one step that must trigger a downstream workflow uses `RELEASE_PAT`, a fine-grained PAT
acting as the repository owner — the credential class that reliably triggers `image.yml`.

#### Operating the pipeline

- **On demand**: Actions → "Release prep" → "Run workflow" with the `new_tag` input. Re-runs are
  safe: an already-released tag skips the whole pipeline, the downgrade guard blocks backwards
  releases, and every failure lands on the tracker issue.
- **Audit trail**: agent reports, contract reports and failure notes all land on the tracker issue;
  full logs live in the workflow runs.
- **PAT expiry**: when `RELEASE_PAT` expires, every stage still runs and the pipeline stops at
  ready-to-release with manual `git tag` instructions on the tracker issue — expiry degrades to the
  manual path instead of breaking anything.
- **Agent repair branches** (`release-prep/<tag>`) are pushed even when a later stage fails, so
  proposed repairs stay inspectable; only a fully green `verify` lets the release job touch `main`.

Configuration for `release-prep.yml`:

| Setting | Kind | Purpose |
|---|---|---|
| `CODEX_BASE_URL` | secret | Model endpoint for the codex agent (any OpenAI-compatible URL) |
| `CODEX_MODEL` | secret | Model name (e.g. `deepseek-chat`) |
| `CODEX_WIRE_API` | variable | `chat` (default, for OpenAI-compatible endpoints; requires the pinned codex ≤ 0.90.x) or `responses` (OpenAI official; enables newer codex) |
| `CODEX_API_KEY` | secret | API key for the model endpoint |
| `RELEASE_PAT` | secret | Optional fine-grained PAT (Contents: Read and write on this repository) whose push publishes the release tag. Neither a `GITHUB_TOKEN` push nor a GitHub App installation-token push triggers `image.yml` (verified live), so a user PAT is the reliable trigger. Without it, the pipeline stops at ready-to-release and posts manual `git tag` instructions to the tracker issue |

The pipeline can also be run on demand: Actions → "Release prep" → "Run workflow" with the
`new_tag` input.

### Dependabot (`.github/dependabot.yml`)

Weekly version updates for the dependencies that are pinned in this repository:

- `github-actions` — the action pins in `image.yml` (`actions/checkout`, `docker/*`,
  `softprops/action-gh-release`);
- `docker` — the `debian:13-slim` base image in the `Containerfile` (uv switched to the official
  installer script, so it is no longer a Dependabot-managed pin).

Upstream dsh tags are intentionally *not* covered by Dependabot — it has no ecosystem for watching
another repository's git tags; that is the watcher workflow's job.

## Upgrading data volumes to the image-owned toolchain

The image carries the whole toolchain (uv/pnpm in `/usr/local/bin`, Rust toolchains in
`/opt/rust`, dsh in `/opt/deepseek-harness`) and the `/home/dsh` volume holds only data and caches.
Volumes created by older images still hold seeded toolchain copies (`~/.local/bin` uv/uvx, the
pnpm prefix under `~/.local/share/pnpm`, rustup proxies in `~/.cargo/bin`, and the `~/.rustup`
tree). They are inert — PATH prefers the image-owned binaries and they can never shadow them — but
waste space (~1GB for `~/.rustup`). Remove them manually inside the container if desired; the same
text ships in each release note:

```bash
rm -rf ~/.local/bin/uv ~/.local/bin/uvx ~/.local/bin/pnpm \
       ~/.local/share/pnpm/lib/node_modules/pnpm ~/.local/share/pnpm/bin/pnpm
# only if you keep no custom toolchains (~/.rustup is ~1GB):
rm -rf ~/.rustup ~/.cargo/bin/cargo ~/.cargo/bin/rustc ~/.cargo/bin/rustdoc \
       ~/.cargo/bin/rustup ~/.cargo/bin/rust-gdb ~/.cargo/bin/rust-lldb \
       ~/.cargo/bin/rust-lldb-server
```

Caches (`~/.cargo/registry`, `~/.local/share/uv`, the pnpm store), `~/.dsh`, and user-installed
tools stay on the volume unchanged.

## Cleaning up published images

Deleting package versions requires the `read:packages` / `delete:packages` scopes on the token
(`gh auth refresh -h github.com -s read:packages,write:packages,delete:packages` to add them):

```bash
# 1. list all versions (confirm before deleting)
gh api /user/packages/container/dsh-container/versions \
  --jq '.[] | "\(.id)  \(.name)  tags=\([.metadata.container.tags[]] | join(","))"'

# 2. delete every version
gh api /user/packages/container/dsh-container/versions --jq '.[].id' | while read -r id; do
  gh api --method DELETE "/user/packages/container/dsh-container/versions/$id" >/dev/null \
    && echo "deleted version $id"
done
```

- Deleting **versions** keeps the package; the next release tag recreates `dsh-v*` + `<sha>` +
  `latest`.
- Deleting the **whole package** removes its settings too; after recreating the package, set its
  visibility in the GitHub package settings if public pulls are needed.
