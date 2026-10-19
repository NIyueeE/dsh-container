#!/usr/bin/env node
// 判断 NEW_TAG 是否为本仓库现有的最新 dsh-v* tag。NEW_TAG 必须已经是完整
// tag 名(如 dsh-v0.2.1-rc.2); EXISTING 是换行分隔的完整 tag 列表。
//
// 与 upstream-tag.yml 的排序键一致: 核心版本各段定宽; 预发布段逐标识符编码
// (数字段加 "0" 前缀并补零, 字母数字段加 "1" 前缀), 稳定版用 "~"。
// 这样 0.1.2-alpha.4 < 0.1.2 < 0.1.10, 不依赖 git version sort。
//
// 输出: "true" | "false"。非法 tag 或空输入直接失败(调用方 fail closed)。
const key = (v) => {
  const m = /^dsh-v(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z.-]+))?$/.exec(v)
  if (!m) return null
  const core = [m[1], m[2], m[3]].map((s) => s.padStart(8, '0')).join('.')
  const pre = m[4]
    ? m[4].split('.').map((id) => (/^\d+$/.test(id) ? '0' + id.padStart(12, '0') : '1' + id)).join('.')
    : '~'
  return core + '|' + pre
}

const current = key(process.env.NEW_TAG ?? '')
if (current === null) {
  console.error('newest-tag: invalid NEW_TAG: ' + String(process.env.NEW_TAG))
  process.exit(1)
}

const existing = (process.env.EXISTING ?? '')
  .split('\n')
  .map((tag) => tag.trim())
  .filter(Boolean)
  .map(key)
  .filter((k) => k !== null)

process.stdout.write(existing.some((k) => k > current) ? 'false' : 'true')
