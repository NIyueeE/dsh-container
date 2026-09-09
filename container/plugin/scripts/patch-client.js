#!/usr/bin/env node
// dsh-container 浏览器端兼容补丁(构建期, 迁移自旧 container/dsh-client-patch.sh):
// 把 dsh-client-connection 编译产物里的 isLoopback 表达式替换为恒 true。
//
// Caddy 反代把 Host/Origin 改写成回环, 服务端 /api 信任围栏因此放行所有
// 特权接口; 但上游浏览器代码仍按 window.location.hostname 判断是否回环,
// 导致远程浏览器无法使用设置/凭据页(上游 trustedHosts 只作用于服务端
// 围栏)。浏览器 bundle 是构建产物, 运行期插件无法改写, 只能在此处
// 做字符串补丁 —— 这是本仓库唯一改动上游构建产物的位置。
//
// 用法: node patch-client.js [--dsh-root <path>]
//   默认 DSH_CLIENT_PATCH_ROOT 环境变量, 再默认 /opt/deepseek-harness。
// 行为: 幂等(已打过则跳过); 找不到模式时打印警告并 exit 0, 不阻塞启动。
// 上游核对(dsh-v0.1.5-alpha.1): isLoopback 表达式见
// packages/client/connection/src/client/index.ts:227, 与候选串一致。
import { existsSync } from 'node:fs'
import { readFile, writeFile } from 'node:fs/promises'
import { join } from 'node:path'

const MARKER = 'dsh-container remote-proxy patch'
const REPLACEMENT = `isLoopback: true, // ${MARKER}`
const CANDIDATES = [
  'isLoopback: transport?.ownsHost === true || pageLocation === void 0 || isLoopbackHostname(pageLocation.hostname),',
  'isLoopback: pageLocation === void 0 || isLoopbackHostname(pageLocation.hostname),',
]

const argRoot = process.argv.indexOf('--dsh-root')
const root = argRoot >= 0
  ? process.argv[argRoot + 1]
  : (process.env.DSH_CLIENT_PATCH_ROOT ?? '/opt/deepseek-harness')

const BUNDLE_CANDIDATES = [
  join(root, 'packages/client/connection/lib/client.js'),
  join(root, 'node_modules/@deepseek-ai/dsh-client-connection/lib/client.js'),
]

function findBundle() {
  for (const candidate of BUNDLE_CANDIDATES) {
    if (existsSync(candidate)) return candidate
  }
  return undefined
}

async function main() {
  const bundle = findBundle()
  if (bundle === undefined) {
    console.error('[patch-client] dsh-client-connection bundle not found; skipping isLoopback patch')
    return
  }
  let src
  try {
    src = await readFile(bundle, 'utf8')
  } catch {
    console.error(`[patch-client] cannot read ${bundle}; skipping isLoopback patch`)
    return
  }
  if (src.includes(MARKER)) {
    console.log('[patch-client] isLoopback already patched')
    return
  }
  const old = CANDIDATES.find((candidate) => src.includes(candidate))
  if (old === undefined) {
    console.error('[patch-client] isLoopback pattern not found; upstream may have changed; skipping')
    return
  }
  await writeFile(bundle, src.split(old).join(REPLACEMENT))
  console.log('[patch-client] isLoopback patched')
}

void main()
