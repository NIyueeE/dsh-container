#!/usr/bin/env node
// dsh-container 构建期产物后处理 #2: 用 esbuild 逐包压缩客户端产物。
//
// 为什么: 上游刻意不压缩自己的客户端 bundle(保留可读产物与源映射链), 于是
// 每个浏览器冷启动都要下载并解析 2.9 MB(去图后)的未压缩 JS。同一份代码压缩后
// 实测(57 模块合并包, 已去内联大图): raw 5.31 MB -> 3.02 MB, gzip 1.24 MB ->
// 0.83 MB, 客户端要解析执行的源码少 43%。
//
// 压缩档位: --minify --keep-names --target=esnext
//   - keep-names: 产物里有 584 处 `.name` 读取, 且 Cordis 用 plugin.name 做运行期
//     记录/日志名。保留函数与类名只多约 5% gzip, 把"改名类"故障面直接归零。
//   - esnext: 只压缩, 不做语法降级(上游客户端产物没有 target 约束)。
//   - 不做属性改名(esbuild 默认不 mangle properties), 因此 isLoopback、
//     __ModuleLoader__、服务名等标识符原样保留。
//
// 源映射: 输入产物自带 client.js.map, esbuild 会读取并串联它; 输出经临时目录
// 原子替换 .js 与 .js.map(避免"边读边写"覆盖输入映射)。
//
// 用法: node minify-client.mjs --esbuild <esbuild 可执行文件> [--root <dsh-root>]
// 自检: 每个压缩后的产物必须仍含 __ModuleLoader__.load, 否则非零退出。
import { spawnSync } from 'node:child_process'
import { existsSync, globSync, mkdtempSync, readFileSync, renameSync, rmSync, statSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join, resolve } from 'node:path'

const DEFAULT_ROOT = '/opt/deepseek-harness'
const ARTIFACT_PATTERNS = [
  'packages/*/*/lib/client.js',
  'packages/*/*/lib/client.*.js',
]

function flag(name, fallback) {
  const at = process.argv.indexOf(`--${name}`)
  return at >= 0 && process.argv[at + 1] !== undefined ? process.argv[at + 1] : fallback
}

// esbuild 可执行文件由调用方(Containerfile)显式传入固定版本的绝对路径; 缺省回退到
// PATH 上的 esbuild, 便于本地手动跑。
const esbuild = flag('esbuild', 'esbuild')
const root = resolve(flag('root', DEFAULT_ROOT))

const probe = spawnSync(esbuild, ['--version'], { encoding: 'utf8' })
if (probe.status !== 0) {
  console.error(`[minify-client] cannot run esbuild at ${esbuild}: ${probe.stderr ?? probe.error?.message ?? ''}`)
  process.exit(1)
}

const files = ARTIFACT_PATTERNS
  .flatMap(pattern => globSync(pattern, { cwd: root }))
  .filter(path => statSync(join(root, path)).isFile())
  .sort()
if (files.length === 0) {
  console.error(`[minify-client] no client artifacts under ${root}; run a complete build first`)
  process.exit(1)
}

let before = 0
let after = 0
for (const path of files) {
  const absolute = join(root, path)
  const size = statSync(absolute).size
  const work = mkdtempSync(join(tmpdir(), 'dsh-minify-'))
  try {
    const result = spawnSync(esbuild, [
      absolute,
      '--minify',
      '--keep-names',
      '--target=esnext',
      '--sourcemap',
      '--log-level=error',
      `--outfile=${join(work, 'client.js')}`,
    ], { encoding: 'utf8' })
    if (result.status !== 0) {
      console.error(`[minify-client] esbuild failed for ${path}: ${result.stderr ?? ''}`)
      process.exit(1)
    }
    const minified = readFileSync(join(work, 'client.js'))
    if (!minified.includes('__ModuleLoader__.load')) {
      console.error(`[minify-client] ${path} lost its module-loader registration after minification`)
      process.exit(1)
    }
    renameSync(join(work, 'client.js'), absolute)
    const map = join(work, 'client.js.map')
    if (existsSync(map)) renameSync(map, `${absolute}.map`)
    const next = statSync(absolute).size
    before += size
    after += next
    console.log(`[minify-client] ${path}: ${(size / 1024).toFixed(0)} KiB -> ${(next / 1024).toFixed(0)} KiB`)
  } finally {
    rmSync(work, { recursive: true, force: true })
  }
}

console.log(
  `[minify-client] esbuild ${probe.stdout.trim()}: ${(before / 1024 / 1024).toFixed(2)} MiB -> `
  + `${(after / 1024 / 1024).toFixed(2)} MiB across ${String(files.length)} artifacts`,
)
