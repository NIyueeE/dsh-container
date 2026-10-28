// Shared semver ordering for `dsh-v*` tags. Several places used to carry their own
// copy of this logic (newest-tag.mjs, upstream-tag.yml, the publish downgrade
// guard); one module keeps them from drifting.
//
// Key format: core segments padded to 8 digits; prerelease identifiers encoded
// one by one (numeric -> "0" + 12-digit pad, alphanumeric -> "1" + text), and a
// stable release uses "~" (ASCII max). So 0.1.2-alpha.4 < 0.1.2 < 0.1.10,
// unlike GNU `sort -V`.

/** @param {string} tag full tag name, e.g. `dsh-v0.2.1-rc.2` @returns {string|null} */
export function key(tag) {
  const m = /^dsh-v(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z.-]+))?$/.exec(tag)
  if (!m) return null
  const core = [m[1], m[2], m[3]].map((s) => s.padStart(8, '0')).join('.')
  const pre = m[4]
    ? m[4].split('.').map((id) => (/^\d+$/.test(id) ? '0' + id.padStart(12, '0') : '1' + id)).join('.')
    : '~'
  return core + '|' + pre
}

/** @param {string} names newline-separated tag names @returns {string} newest valid tag or '' */
export function newest(names) {
  const tags = (names ?? '')
    .split('\n')
    .map((t) => t.trim())
    .filter(Boolean)
    .map((t) => [key(t), t])
    .filter(([k]) => k !== null)
    .sort((a, b) => (a[0] < b[0] ? -1 : a[0] > b[0] ? 1 : 0))
  return tags.length ? tags[tags.length - 1][1] : ''
}
