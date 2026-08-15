# Image Tags & Publishing

## Image tags

| Tag | Source | Description |
|---|---|---|
| `v*` (e.g. `v1.2.0`) | version tags | semantic versions — the release artifact |
| `latest` | newest `v*` release | points to the most recent release; what the examples pull |
| `<commit-sha>` | release builds | exactly reproducible |

## CI release workflow

Pushing to GitHub triggers [`.github/workflows/image.yml`](../.github/workflows/image.yml):

- **main / PR / manual dispatch**: build + smoke test a temporary image only — **nothing is pushed
  to GHCR**. CI validates that the image is usable, nothing more.
- **`v*` tag (release)**: build + smoke test, and only after the smoke test passes push
  `v*` + `<sha>` + `latest` to GHCR, then create a **GitHub Release page** (auto-generated notes).
  A broken image never reaches the registry; the release is not created if build or smoke fails.

### Version alignment (image version only)

For a tag build, one version string flows through the image's own release:

- git tag `v1.2.0` → Release page `v1.2.0` → image tag `ghcr.io/niyueee/dsh-container:v1.2.0`
- OCI label `org.opencontainers.image.version` = `1.2.0` (leading `v` stripped), via the
  `BUILD_VERSION` build arg (`latest` for non-release builds, which are never published)

The image version is **decoupled from the dsh npm version**: `DSH_VERSION` is not derived from the
tag. By default every build installs the npm `latest` at build time, and runtime auto-update is off
(`DSH_AUTO_UPDATE=0`), so the installed version stays put until the next image release. To pin dsh
inside a published image, set the repository variable **`DSH_VERSION`** (Settings → Variables →
Actions); CI passes it as a build arg when set. Local/manual builds can pin directly with
`--build-arg DSH_VERSION=x.y.z` (see [build.md](build.md)).

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

- Deleting **versions** keeps the package; the next release tag recreates `v*` + `<sha>` +
  `latest`.
- Deleting the **whole package** removes its settings too; after recreating the package, set its
  visibility in the GitHub package settings if public pulls are needed.
