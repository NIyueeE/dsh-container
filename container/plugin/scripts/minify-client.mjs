#!/usr/bin/env node
// dsh-container 构建期产物后处理 #2: 用 esbuild 逐包压缩客户端产物。
//
// 为什么: 上游刻意不压缩自己的客户端 bundle(保留可读产物与源映射链), 于是浏览器冷
// 启动要下载并解析 10.0 MiB 的合并包。抽图后剩约 5.1 MiB, 再压空白与语法后 3.59 MiB;
// 线上字节(无头浏览器实测, 57 模块合并包)5.06 MiB -> 1.02 MiB, 整页冷启动
// 5.76 MiB -> 1.64 MiB。
//
// 压缩档位: --minify-whitespace --minify-syntax (不压缩标识符!)
//   dsh 把多个客户端产物拼成**一个响应**(`plugins/??a/client.js,b/client.js…`),
//   浏览器把它当**一个脚本**求值: 各文件顶层的声明共享同一作用域, 且 factory 是在
//   整段脚本求值之后才被 materialize 的。于是"改标识符"的压缩档位会致命 ——
//   每个文件顶层都有自己的短名 helper(实测同一 combo 里出现 s/g/c/o/u/a 等),
//   `var` 相互覆盖后, 先注册的模块 body 会调用到**别的文件**的同名 helper:
//   实测 `u(S,"v")` 落到另一文件的 `(o,k,d)=>Object.defineProperty(o,k,d)` 上,
//   变成 defineProperty(S,"v",undefined) → "Property description must be an
//   object: undefined", 58/65 个客户端插件激活失败(无头浏览器实测)。上游未压缩
//   产物的 helper 语义一致(__defProp/__name), 同名覆盖无害; 一旦改标识符就必然
//   出现语义不同的同名碰撞。因此压缩上限就是"空白 + 语法", 标识符保持原样 ——
//   顺带也保住了 584 处 `.name` 读取与 Cordis 的 plugin.name 记录, 不需要 keep-names。
//   - esnext: 只压缩, 不做语法降级(上游客户端产物没有 target 约束)。
//   - 不做属性改名(esbuild 默认不 mangle properties), 因此 isLoopback、
//     __ModuleLoader__、服务名等标识符原样保留。
//
// 源映射: 输入产物自带 client.js.map, esbuild 会读取并串联它; 输出经临时目录
// 原子替换 .js 与 .js.map(避免"边读边写"覆盖输入映射)。临时输出沿用产物自己的
// 文件名(client.js / client.pdf.js …), 否则 esbuild 写进产物的
// `sourceMappingURL=client.js.map` 会与实际 map 名不符。
//
// 用法: node minify-client.mjs --esbuild <esbuild 可执行文件> [--root <dsh-root>]
// 自检: 压缩不得丢失 loader 注册 —— 逐文件比较 `__ModuleLoader__.<fn>(` 调用数,
// 基准取 esbuild 去注释(--minify-whitespace)后的结果: 上游产物常在文档注释里写
// `window.__ModuleLoader__.load({id, factory})` 这种 API 示例, 直接数原文会把注释
// 算进去, 压缩删注释后就成了假性缺失。计数变少即非零退出。
import { spawnSync } from 'node:child_process'
import { existsSync, globSync, mkdtempSync, readFileSync, renameSync, rmSync, statSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { basename, join, resolve } from 'node:path'

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

/**
 * 统计 `__ModuleLoader__.<fn>(` 形式的注册调用数。
 * 用代码级模式而不是裸标识符: 有的产物只在注释里提到 `__ModuleLoader__`
 * (例如 webworker 页面包), 压缩删注释后裸标识符计数会假性归零。
 * @param {string} text - 产物源码。
 * @returns {number} 注册调用次数。
 */
function loaderRegistrations(text) {
  return (text.match(/__ModuleLoader__\s*\.\s*[A-Za-z_$][\w$]*\s*\(/g) ?? []).length
}

/**
 * 用同一个 esbuild 把产物压成"去注释但未精简单"的基准文本。
 * @param {string} absolute - 产物绝对路径。
 * @param {string} work - 临时目录。
 * @returns {string} 去注释后的源码(失败时抛出)。
 */
function baselineText(absolute, work) {
  const out = join(work, 'baseline.js')
  const result = spawnSync(esbuild, [
    absolute,
    '--minify-whitespace',
    '--target=esnext',
    '--log-level=error',
    `--outfile=${out}`,
  ], { encoding: 'utf8' })
  if (result.status !== 0) {
    throw new Error(`esbuild baseline pass failed: ${result.stderr ?? ''}`)
  }
  return readFileSync(out, 'utf8')
}

let before = 0
let after = 0
for (const path of files) {
  const absolute = join(root, path)
  const size = statSync(absolute).size
  const work = mkdtempSync(join(tmpdir(), 'dsh-minify-'))
  const name = basename(absolute)
  try {
    const registrations = loaderRegistrations(baselineText(absolute, work))
    const result = spawnSync(esbuild, [
      absolute,
      '--minify-whitespace',
      '--minify-syntax',
      '--target=esnext',
      '--sourcemap',
      '--log-level=error',
      `--outfile=${join(work, name)}`,
    ], { encoding: 'utf8' })
    if (result.status !== 0) {
      console.error(`[minify-client] esbuild failed for ${path}: ${result.stderr ?? ''}`)
      process.exit(1)
    }
    const minified = readFileSync(join(work, name), 'utf8')
    const kept = loaderRegistrations(minified)
    if (kept < registrations) {
      console.error(
        `[minify-client] ${path} lost module-loader registrations after minification `
        + `(${String(registrations)} -> ${String(kept)})`,
      )
      process.exit(1)
    }
    renameSync(join(work, name), absolute)
    const map = join(work, `${name}.map`)
    if (existsSync(map)) renameSync(map, `${absolute}.map`)
    const next = statSync(absolute).size
    before += size
    after += next
    console.log(`[minify-client] ${path}: ${(size / 1024).toFixed(0)} KiB -> ${(next / 1024).toFixed(0)} KiB`)
  } catch (error) {
    console.error(`[minify-client] ${path}: ${error instanceof Error ? error.message : String(error)}`)
    process.exit(1)
  } finally {
    rmSync(work, { recursive: true, force: true })
  }
}

console.log(
  `[minify-client] esbuild ${probe.stdout.trim()}: ${(before / 1024 / 1024).toFixed(2)} MiB -> `
  + `${(after / 1024 / 1024).toFixed(2)} MiB across ${String(files.length)} artifacts`,
)
