# Image Tags & Publishing

## Image tags

| Tag | Source | Description |
|---|---|---|
| `latest` | main branch | rolling updates |
| `<commit-sha>` | every push | exactly reproducible |
| `v*` (e.g. `v1.2.0`) | version tags | semantic versions |

## CI release workflow

Pushing `main` or a `v*` tag to GitHub triggers
[`.github/workflows/image.yml`](../.github/workflows/image.yml):

- main → `latest` + `<sha>`; tag → `v*` + `<sha>`;
- every build runs smoke tests (Web UI reachable, dsh/toolchain versions, idempotent update script);
- PRs only build + smoke test, no push;
- a `v*` tag additionally creates a **GitHub Release page** (auto-generated notes) once the image is
  built and smoke-tested — the release is not created if the build or smoke test fails.

### Version alignment

For a tag build, one version string flows through everything:

- git tag `v1.2.0` → Release page `v1.2.0` → image tag `ghcr.io/niyueee/dsh-container:v1.2.0`
- OCI label `org.opencontainers.image.version` = `1.2.0` (leading `v` stripped), via the
  `BUILD_VERSION` build arg (`latest` on main, matching the rolling tag)
- if `@deepseek-ai/dsh@1.2.0` exists on npm, `DSH_VERSION` is pinned to `1.2.0` so the in-image dsh
  matches the release; otherwise CI warns and keeps `DSH_VERSION=latest` (the image version and the
  dsh npm version are intentionally decouplable)

## First release (one-time manual step)

GHCR packages default to **private**, and GitHub has removed the REST API endpoint for changing
package visibility (both `POST` and `PATCH /user/packages/container/<name>/visibility` return 404).
So after the first CI publish you must manually make the package **public** — the package is already
linked to this repository via the `org.opencontainers.image.source` label, and access inherits from
the repo; only the visibility needs to be set manually once:

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

- Deleting **versions** keeps the package (and its public visibility); the next CI publish
  recreates `latest` + `<sha>` on the next main push.
- Deleting the **whole package** (`gh api --method DELETE /user/packages/container/dsh-container`)
  also drops the visibility setting — a freshly published package defaults back to **private** and
  the "First release" manual step must be repeated.
