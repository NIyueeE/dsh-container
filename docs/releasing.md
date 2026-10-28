# Image Tags & Publishing

## Image tags

Each release pushes one multi-platform image (Linux `amd64` + `arm64`) with three tags:

| Tag | Source | Description |
|---|---|---|
| `dsh-v*` (e.g. `dsh-v0.2.1-rc.2`) | upstream dsh tags | the release artifact; image tag, release page tag, and built dsh source tag are all the same upstream tag |
| `latest` | newest `dsh-v*` release | points to the most recent release; what the examples pull |
| `<commit-sha>` | release builds | exactly reproducible |

The version tag keeps the full `dsh-` prefix and is not published as a bare `v*` tag, so it never
collides with older container-image tags such as `v0.2.2`.

Re-pushing an **older** `dsh-v*` tag is refused: the publish workflow's guard compares the tag with
the newest existing `dsh-v*` tag and stops before building anything, leaving the tag in place for
inspection. Re-pushing the **newest** tag is allowed (that is how a failed publish is retried).

## Publish workflow (`.github/workflows/publish.yml`)

A release **is** a tag push: `on: push: tags: ['dsh-v*']` is the only trigger. Pushing the tag is the
manual path; the watcher below pushes it for you when a new upstream tag appears.

```text
git push origin dsh-v0.2.1-rc.2
        │
        ▼
guard    refuse tags older than the newest dsh-v* ; a rerun always rebuilds
  │
light    tests/validate-static.sh + tests/validate-workflows.sh   (reuses ci.yml)
  │
build    amd64 + arm64 in parallel, each pushed BY DIGEST (no tag yet)
  │
smoke    smoke.yml: both architectures, tests/smoke.sh, pure gate → ok
  │
publish  imagetools create → :<tag> + :<sha> (+ :latest when newest)
         assert the merged manifest lists both real platforms (attestations ignored)
         gh release create/edit  →  close the tracker issue
```

The smoke run pulls **the exact digests that are about to be merged**, so the tested artifact is the
published one. `smoke.yml` never pushes, tags, or comments — it only reports `ok`.

Failures do not leave a half-published tag behind: when no image tag was created, the `finalize` job
deletes the git tag (after confirming it still points at the same commit and that `:<tag>` does not
exist in GHCR). Once the image tag exists, the tag is kept and only the missing Release is reported.

The workflow is idempotent — re-running it for the same tag re-merges the same digests and edits the
existing Release — and refuses tags older than the newest `dsh-v*` tag, leaving them in place.

### Gates

| Gate | Defined in | What it proves | Cost |
|---|---|---|---|
| light | `ci.yml` / `light` | shellcheck, plugin contract, docs links/parity, actionlint + zizmor, compose/quadlet — no image is built | ~1.5 min |
| heavy | `smoke.yml` | the image actually runs: login redirect, session cookie, `/api` fence, plugin assets and build record, telemetry default, provenance/OCI labels/platform, both architectures | ~20 min, 2 builds |

`main` pushes always run the light gate and run the heavy gate only when the diff touches the
runtime surface — `Containerfile`, `container/**`, `tests/smoke.sh`,
`.github/workflows/smoke.yml`. A diff that cannot be computed (force push, missing base) forces the
heavy gate. Pull requests run the light gate only; every publish runs both.

### Release notes

The Release page body is composed at publish time by the `release` job and contains only:

1. the upstream release notes for the same tag, quoted verbatim in a collapsed `<details>` block
   (fetched through the GitHub API; if the upstream tag has no Release page, only the link is
   emitted),
2. GitHub's auto-generated commit list for this repository (`generate_release_notes`).

The upstream notes are the authority on per-version migrations (session-log format, settings/preset
storage, provider configuration) — this repository deliberately does not restate them per release,
and does not repeat this image's own upgrade guidance on every Release page. That guidance is
durable documentation instead: [deployment.md](deployment.md) § 4 (the one-way volume rule) and
[§ Upgrading data volumes to the image-owned toolchain](#upgrading-data-volumes-to-the-image-owned-toolchain)
below (the pre-toolchain-layout cleanup commands).

### Tag alignment

For a tag build, one version string flows through the whole release:

- upstream dsh tag `dsh-v0.2.1-rc.2` → release page `dsh-v0.2.1-rc.2` → image tag
  `ghcr.io/niyueee/dsh-container:dsh-v0.2.1-rc.2`
- `Containerfile` checks out that same tag before `pnpm install` / `pnpm run build:official`
- OCI label `org.opencontainers.image.version` = `dsh-v0.2.1-rc.2`, via the `BUILD_VERSION`
  build arg (`latest` for non-release builds, which are never published)

Releases are created by pushing the matching tag to this repository. The upstream watcher below
does it automatically when `RELEASE_PAT` is configured; otherwise (and whenever you want to cut a
release by hand) the commands are:

```bash
git tag dsh-v0.2.1-rc.2
git push origin dsh-v0.2.1-rc.2
```

For local/manual builds, pin directly with `--build-arg DSH_TAG=dsh-v0.2.1-rc.2` (see
[build.md](build.md)).

## Tracking upstream releases

There is no version pin in this repository to bump: pushing the matching upstream tag here **is**
the release. One scheduled watcher keeps the tags in sync (plus Dependabot for action and base
image pins):

### Upstream tag watcher (`.github/workflows/upstream-tag.yml`)

Dependabot cannot watch another repository's git tags, so a small scheduled workflow does it.
Running every 6 hours (plus on every `dsh-v*` tag push and on manual dispatch), it compares the newest
`dsh-v*` tag of `deepseek-ai/deepseek-harness` with the newest `dsh-v*` tag of this repository
(semver-aware, so a stable tag outranks its pre-releases: `dsh-v0.2.1-alpha.5` < `dsh-v0.2.1`).
The schedule is `0 */6 * * *` (every 6 hours), plus the usual `dsh-v*` tag push / manual
dispatch. Actions' `schedule` is best-effort queueing: measured runs landed 4–9 h late, so a
single daily run could take ~30 h to notice a new upstream tag; four runs a day cap the worst case
at ~10–15 h.

- **upstream ahead** → opens one tracker issue ("New upstream dsh release available: …") with the
  release-notes link, the upstream diff, and the manual `git tag` / `git push` commands. When
  `RELEASE_PAT` is configured it also creates that tag at the tip of `main` and pushes it, which is
  what starts the publish pipeline — unless the tag already failed a publish within the last 24
  hours, in which case the watcher stays quiet (that backoff stops a broken tag from rebuilding
  every 6 hours);
- **tags equal** → tracker issues whose tag now has a GitHub Release are closed. The same run does a
  **release health check** on the newest tag: no Release ⇒ it opens/keeps "Release pipeline not
  published: `<tag>`" with the latest `publish.yml` run link and the `gh run download` commands.
  Runs triggered by a tag push skip the check (a publish takes ~25 minutes and would otherwise look
  like a failure); the 6-hourly schedule picks it up.

The upstream repository can be overridden with the `DSH_UPSTREAM_REPO` repository variable
(default `deepseek-ai/deepseek-harness`); the publish workflow uses it for the Release notes too.
To re-check on demand, run "Upstream dsh tag watch" → "Run workflow" from the Actions tab.

### Why the watcher needs a PAT

Pushes made with `GITHUB_TOKEN` or a GitHub App installation token do **not** trigger workflows, so a
tag pushed with the built-in token would never start `publish.yml`. `RELEASE_PAT` (fine-grained:
Contents read/write plus **Workflows read/write**) is what makes the watcher's tag push start the
pipeline. Without the secret the watcher only comments the manual commands — the manual path still
works, it is just not automatic. `.github/workflows/pat-trigger-probe.yml` verifies that credential
on demand.

### Diagnosing a failed publish

Every smoke run uploads `smoke-diagnostic-amd64` / `smoke-diagnostic-arm64` (JSON + Markdown + the
full log, 14 days) and appends the Markdown to the job summary. The JSON carries the failing check
id, its message, per-check timings, the last 60 log lines of each container, and a reproduce command.

```bash
gh run view <run-id> --log-failed
gh run download <run-id> -n smoke-diagnostic-amd64 -D ./diag
jq '.failed_check, .message' ./diag/smoke-diag/smoke-diagnostic.json
```

A failed publish also PATCHes one status comment on the tracker issue for that tag ("New upstream
dsh release available: `<tag>`") with the same information, so the issue is the first place to look.
CI smoke failures on `main` deliberately post no issue comment — use the commands above.

### Retrying a failed publish

Fix the cause, then push the tag again (the cleanup deleted it, so this creates it rather than
force-moving it):

```bash
git tag -f dsh-v0.2.1-rc.2 <fixed-commit>
git push -f origin dsh-v0.2.1-rc.2
```

The watcher's 24-hour backoff only affects its own automatic re-tagging; a manual push always works.

### Dependabot (`.github/dependabot.yml`)

Weekly version updates for the dependencies that are pinned in this repository:

- `github-actions` — the action pins in every workflow (`actions/checkout`, `docker/*`,
  `actions/upload-artifact`, `actions/download-artifact`);
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
waste space (~1GB for `~/.rustup`). Remove them manually inside the container if desired:

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
