#!/usr/bin/env node
// dsh-container 构建期产物后处理 #1: 把客户端产物里的大图从内联 data URL 抽成
// 真实文件, 让浏览器只在真正需要时才下载它们。
//
// 为什么要做: 上游客户端构建 preset 没有图片 emitter, TSX 里的
// `import art from './assets/x.png'` 会被 rolldown 内联成 base64 data URL。
// 实测 8 张账号引导插画(333-581 KB, 按语言 x 主题各一份)内联后占 57 模块合并包
// 的 49% —— 而任何用户实际只会用到其中 1 张, 却是每次冷启动全量下载。抽成文件后
// 由容器适配插件的 /container-assets 路由提供(内容哈希 + immutable), 只在真的
// 进入该引导页时才请求。
//
// 阈值: 只处理解码后 >= 100 KiB 的图片。小图(如运行态鲸鱼 APNG 28 KB)保持内联 ——
// 它必须首帧就到, 抽出去会出现"蒙版未加载"的空窗。
//
// 用法: node extract-inline-assets.js [--root <dsh-root>] [--out <dir>] [--min-bytes <n>]
// 幂等: 产物里已无 >= 阈值的 data URL 时不做任何改动, 可重复执行。
// 失败策略: 解码或魔数校验失败 -> 非零退出(构建必须失败); 一个候选都没有 ->
// 提示后以 0 退出(上游若改为 emit 文件, 这是正常结果, 由 smoke 断言兜底)。
import { createHash } from 'node:crypto'
import { existsSync, globSync, mkdirSync, readFileSync, statSync, writeFileSync } from 'node:fs'
import { join, resolve } from 'node:path'

const ASSET_ROUTE = '/container-assets'
const DEFAULT_ROOT = '/opt/deepseek-harness'
const DEFAULT_OUT = '/opt/dsh-container-plugin/assets'
const DEFAULT_MIN_BYTES = 100 * 1024
const ID_LENGTH = 16

/** 产物模式: 与 client-build-environment.ts 的 CLIENT_ARTIFACT_PATTERNS 对齐(去掉 sourcemap)。 */
const ARTIFACT_PATTERNS = [
  'packages/*/*/lib/client.js',
  'packages/*/*/lib/client.*.js',
]

const DATA_URL = /data:image\/(png|jpeg|jpg|webp|gif);base64,([A-Za-z0-9+/=]+)/g

/** 每种格式的魔数前缀, 用于确认解码结果确实是声明的图片类型。 */
const MAGIC = {
  png: [[0x89, 0x50, 0x4e, 0x47]],
  jpeg: [[0xff, 0xd8, 0xff]],
  jpg: [[0xff, 0xd8, 0xff]],
  gif: [[0x47, 0x49, 0x46, 0x38]],
  webp: [[0x52, 0x49, 0x46, 0x46]],
}

function flag(name, fallback) {
  const at = process.argv.indexOf(`--${name}`)
  return at >= 0 && process.argv[at + 1] !== undefined ? process.argv[at + 1] : fallback
}

const root = resolve(flag('root', process.env.DSH_CLIENT_PATCH_ROOT ?? DEFAULT_ROOT))
const outDir = resolve(flag('out', DEFAULT_OUT))
const minBytes = Number(flag('min-bytes', String(DEFAULT_MIN_BYTES)))
if (!Number.isSafeInteger(minBytes) || minBytes < 1) {
  console.error(`[extract-assets] invalid --min-bytes: ${String(minBytes)}`)
  process.exit(1)
}

/** 校验解码结果与声明类型一致, 不一致直接让构建失败。 */
function assertMagic(kind, bytes, label) {
  const prefixes = MAGIC[kind] ?? []
  const ok = prefixes.some(prefix => prefix.every((byte, at) => bytes[at] === byte))
  if (!ok) {
    console.error(`[extract-assets] ${label}: decoded bytes are not a valid ${kind} image`)
    process.exit(1)
  }
}

/** 内容哈希文件名: 同一张图在多个产物里出现时只落一份盘。 */
function assetName(kind, bytes) {
  const digest = createHash('sha256').update(bytes).digest('hex').slice(0, ID_LENGTH)
  return `${digest}.${kind === 'jpg' ? 'jpeg' : kind}`
}

/** 按内容写盘; 内容一致时跳过写入, 保持 mtime 稳定(?rev 由元数据派生)。 */
function writeAsset(file, bytes) {
  if (existsSync(file) && readFileSync(file).equals(bytes)) return false
  mkdirSync(outDir, { recursive: true })
  writeFileSync(file, bytes)
  return true
}

const files = ARTIFACT_PATTERNS
  .flatMap(pattern => globSync(pattern, { cwd: root }))
  .filter(path => statSync(join(root, path)).isFile())
  .sort()

if (files.length === 0) {
  console.error(`[extract-assets] no client artifacts under ${root}; run a complete build first`)
  process.exit(1)
}

const extracted = new Map()
let rewrittenFiles = 0
let removedBytes = 0

for (const path of files) {
  const absolute = join(root, path)
  const source = readFileSync(absolute, 'utf8')
  let replaced = source
  for (const match of source.matchAll(DATA_URL)) {
    const [literal, kind, base64] = match
    const bytes = Buffer.from(base64, 'base64')
    if (bytes.byteLength < minBytes) continue
    assertMagic(kind, bytes, `${path} (${String(bytes.byteLength)} bytes)`)
    const name = assetName(kind, bytes)
    writeAsset(join(outDir, name), bytes)
    extracted.set(name, (extracted.get(name) ?? 0) + bytes.byteLength)
    replaced = replaced.split(literal).join(`${ASSET_ROUTE}/${name}`)
    removedBytes += literal.length - `${ASSET_ROUTE}/${name}`.length
  }
  if (replaced !== source) {
    writeFileSync(absolute, replaced)
    rewrittenFiles += 1
  }
}

console.log(
  `[extract-assets] scanned ${String(files.length)} artifacts, rewrote ${String(rewrittenFiles)}, `
  + `extracted ${String(extracted.size)} image(s) to ${outDir}, removed ${(removedBytes / 1024 / 1024).toFixed(2)} MiB of inline base64`,
)
for (const [name, bytes] of [...extracted].sort((left, right) => right[1] - left[1])) {
  console.log(`[extract-assets]   ${(bytes / 1024).toFixed(0).padStart(5)} KiB  ${ASSET_ROUTE}/${name}`)
}
if (extracted.size === 0) {
  console.log(
    '[extract-assets] no inline image met the threshold; upstream may have switched to emitted assets '
    + '(the smoke test asserts the served payload carries no large inline image)',
  )
}
