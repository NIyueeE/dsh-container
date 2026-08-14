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
  `BUILD_VERSION` build arg (`latest` on main, matching the rolling tag)

The image version is **decoupled from the dsh npm version**: `DSH_VERSION` is not derived from the
tag. By default every build installs the npm `latest` at build time, and the runtime auto-update
(`DSH_AUTO_UPDATE=1`) keeps dsh current on each boot. To pin dsh inside a published image, set the
repository variable **`DSH_VERSION`** (Settings → Variables → Actions); CI passes it as a build arg
when set. Local/manual builds can pin directly with `--build-arg DSH_VERSION=x.y.z`
(see [build.md](build.md)).

## First release (one-time manual step)

GHCR packages default to **private**, and GitHub has removed the REST API endpoint for changing
package visibility (both `POST` and `PATCH /user/packages/container/<name>/visibility` return 404).
After the first CI publish, the repository owner must manually make the package **public** once —
the package is already linked to this repository via the `org.opencontainers.image.source` label,
and access inherits from the repo; only the visibility needs to be set manually:

1. Open <https://github.com/users/NIyueeE/packages/container/package/dsh-container/settings>
2. **Danger Zone → Change visibility → Public**
3. Afterwards `docker pull ghcr.io/niyueee/dsh-container:latest` should work anonymously.

## Cleaning up published images

Deleting package versions requires the `read:packages` / `delete:packages` scopes on the token
(`gh auth refresh -h github.com -s read:packages,write:packages,delete:packages` to add them):

```bash
# 1. list all versions (confirm before deleting)
gh api /user/packages/container/dsh-container/versions \
  --jq '.[] | "\(.id)  \(.name)  tags=\([.metadata.container.tags[]] | join(","))"'

# 2. delete every version (keeps the package record and its public visibility)
gh api /user/packages/container/dsh-container/versions --jq '.[].id' | while read -r id; do
  gh api --method DELETE "/user/packages/container/dsh-container/versions/$id" >/dev/null \
    && echo "deleted version $id"
done
```

- Deleting **versions** keeps the package (and its public visibility); the next release tag
  recreates `v*` + `<sha>` + `latest`.
- Deleting the **whole package** (`gh api --method DELETE /user/packages/container/dsh-container`)
  also drops the visibility setting — a freshly published package defaults back to **private** and
  the "First release" manual step must be repeated.
