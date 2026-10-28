#!/usr/bin/env node
// `NEW_TAG` 是否为本仓库最新/更新的 dsh-v* tag。
// 输入: NEW_TAG(完整 tag 名), EXISTING(换行分隔的完整 tag 列表), STRICT=1 时
// 把"等于"也算作不新(发布守卫用: 已存在的 tag 不允许再发一次)。
// 输出: "true" | "false"。非法 NEW_TAG 或空输入直接失败(调用方 fail closed)。
//
// 排序键在 ./semver.mjs 里, 与 upstream-tag.yml 用的 compare-tags.mjs 共用一份。
import { key } from './semver.mjs'

const current = key(process.env.NEW_TAG ?? '')
if (current === null) {
  console.error('newest-tag: invalid NEW_TAG: ' + String(process.env.NEW_TAG))
  process.exit(1)
}

const strict = process.env.STRICT === '1'
const existing = (process.env.EXISTING ?? '')
  .split('\n')
  .map((tag) => tag.trim())
  .filter(Boolean)
  .map(key)
  .filter((k) => k !== null)

process.stdout.write(existing.some((k) => (strict ? k >= current : k > current)) ? 'false' : 'true')
