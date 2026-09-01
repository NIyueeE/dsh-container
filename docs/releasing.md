# Image Tags & Publishing

## Image tags

Each release pushes one multi-platform image (Linux `amd64` + `arm64`) with three tags:

| Tag | Source | Description |
|---|---|---|
| `dsh-v*` (e.g. `dsh-v0.1.2-alpha.3`) | upstream dsh tags | the release artifact; image tag, release page tag, and built dsh source tag are all the same upstream tag |
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
  only after the smoke test passes pushes the multi-platform image (`linux/amd64,linux/arm64`)
  with `dsh-v*` + `<sha>` + `latest` to GHCR, then creates a **GitHub Release page**
  (auto-generated notes) with the same tag. A broken image never reaches the registry; the release
  is not created if build or smoke fails.

### Tag alignment

For a tag build, one version string flows through the whole release:

- upstream dsh tag `dsh-v0.1.2-alpha.3` → release page `dsh-v0.1.2-alpha.3` → image tag
  `ghcr.io/niyueee/dsh-container:dsh-v0.1.2-alpha.3`
- `Containerfile` checks out that same tag before `pnpm install` / `pnpm run build:official`
- OCI label `org.opencontainers.image.version` = `dsh-v0.1.2-alpha.3`, via the `BUILD_VERSION`
  build arg (`latest` for non-release builds, which are never published)

Releases are created by pushing the matching tag to this repository:

```bash
git tag dsh-v0.1.2-alpha.3
git push origin dsh-v0.1.2-alpha.3
```

For local/manual builds, pin directly with `--build-arg DSH_TAG=dsh-v0.1.2-alpha.3` (see
[build.md](build.md)).

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
