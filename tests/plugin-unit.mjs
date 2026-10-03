#!/usr/bin/env node
// 容器适配插件的单元验证(无镜像、无网络): 断言两件"只靠代码就能钉住"的契约 ——
//   1. 服务端索引注入 __DSH_TRANSPORT__={ownsHost:true}, 且位置在 <head> 之后
//      (必须先于 type="module" 的 bundle 执行, connection 插件才读得到);
//   2. /container-assets 路由按内容哈希服务抽出的图片(immutable 缓存头),
//      并且拒绝未知名/路径穿越。
// 端到端效果(真实浏览器/真实 dsh)由 tests/smoke.sh 在镜像里断言。
// 用法: node tests/plugin-unit.mjs
import assert from 'node:assert/strict'
import { mkdir, mkdtemp, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { Writable } from 'node:stream'

const ASSET_DIR = '/opt/dsh-container-plugin/assets'

/** 收集 apply() 注册的 effect, 并记录 tap 与路由处理器。 */
function createStubContext() {
  const effects = []
  const registrations = []
  const taps = []
  const ctx = {
    webServer: {
      port: 3080,
      tapIndex: (transform) => {
        taps.push(transform)
        return () => taps.splice(taps.indexOf(transform), 1)
      },
      register: (route) => {
        registrations.push(route)
        return () => registrations.splice(registrations.indexOf(route), 1)
      },
    },
    connection: { authenticatedUrl: (url) => `${url}?token=stub` },
    settings: {},
    settingsController: { describe: () => ({ hasDocument: true }) },
    effect: (callback, label) => {
      const disposer = callback()
      effects.push({ label, disposer })
      return disposer
    },
  }
  return { ctx, effects, registrations, taps }
}

/** 真 Writable 形态的假响应(路由用 stream.pipeline 写 body)。 */
class StubResponse extends Writable {
  constructor() {
    super()
    this.chunks = []
    this.statusCode = 0
    this.headers = {}
  }

  writeHead(status, headers) {
    this.statusCode = status
    this.headers = headers ?? {}
    return this
  }

  _write(chunk, _encoding, callback) {
    this.chunks.push(Buffer.from(chunk))
    callback()
  }
}

/** 把 handler 当成 node:http 响应写手来驱动, 返回状态/头/body。 */
async function callHandler(handler, url) {
  const res = new StubResponse()
  // 监听必须在调用 handler 之前挂上: 短响应(404)在 handler 内就 finish 了。
  const finished = new Promise(resolve => res.once('finish', resolve))
  await handler({ url }, res)
  if (!res.writableFinished) await finished
  return { status: res.statusCode, headers: res.headers, body: Buffer.concat(res.chunks) }
}

const scratch = await mkdtemp(join(tmpdir(), 'dsh-plugin-unit-'))
process.env.DSH_CADDY_RUNTIME_DIR = join(scratch, 'caddy')
// 自举只读取这个 cookie 文件; 提前放一个"已被接受"的 cookie, 走复用路径(不发请求)。
await mkdir(join(scratch, 'caddy'), { recursive: true })
await writeFile(join(scratch, 'caddy', 'session-cookie'), 'dsh-auth-stub=value')

const { ctx, registrations, taps } = createStubContext()
const plugin = await import('../container/plugin/index.js')
assert.equal(plugin.name, 'dsh-container-adapt', 'plugin name changed')
assert.deepEqual(plugin.inject, ['webServer', 'connection', 'settings', 'settingsController'])
plugin.apply(ctx)

assert.equal(taps.length, 1, 'plugin must register exactly one index tap')
assert.equal(registrations.length, 1, 'plugin must register exactly one web route')
assert.deepEqual(
  { kind: registrations[0].kind, path: registrations[0].path },
  { kind: 'prefix', path: '/container-assets' },
  'asset route must be the /container-assets prefix',
)

const tap = taps[0]
const sample = '<!doctype html><html><head><meta charset="utf-8" /><script type="module" src="./assets/index-abc.js"></script></head><body></body></html>'
const injected = tap(sample)
const marker = '<script>globalThis.__DSH_TRANSPORT__={ownsHost:true}</script>'
assert.ok(injected.includes(marker), 'index tap must inject the transport global')
assert.ok(
  injected.indexOf(marker) > injected.indexOf('<head>') && injected.indexOf(marker) < injected.indexOf('assets/index-abc.js'),
  'injection must sit inside <head>, before the shell module script',
)
assert.equal(tap('<html><body>no head</body></html>'), '<html><body>no head</body></html>', 'missing <head> must pass through untouched')
assert.equal(tap(sample), injected, 'index tap must be a pure function')

const handler = registrations[0].handler
const missing = await callHandler(handler, '/container-assets/../../etc/passwd')
assert.equal(missing.status, 404, 'path traversal must be rejected')
const unknown = await callHandler(handler, '/container-assets/deadbeefdeadbeef.png')
assert.equal(unknown.status, 404, 'unknown asset name must 404')

// 抽图产物只在镜像构建期存在; 本地(容器外)运行单元测试时跳过命中路径的验证。
const { existsSync, readdirSync } = await import('node:fs')
if (existsSync(ASSET_DIR)) {
  const name = readdirSync(ASSET_DIR).find(entry => entry.endsWith('.png'))
  if (name !== undefined) {
    const hit = await callHandler(handler, `/container-assets/${name}`)
    assert.equal(hit.status, 200, `serving ${name} must succeed`)
    assert.equal(hit.headers['content-type'], 'image/png')
    assert.equal(hit.headers['cache-control'], 'public, max-age=31536000, immutable')
    assert.equal(hit.body.length, Number(hit.headers['content-length']))
    assert.equal(hit.body[0], 0x89, 'served bytes must be the PNG file itself')
    console.log(`[plugin-unit] asset route served ${name} (${hit.body.length} bytes) with immutable caching`)
  }
} else {
  console.log(`[plugin-unit] ${ASSET_DIR} absent (not running inside the image); skipped the asset-hit assertion`)
}

await rm(scratch, { recursive: true, force: true })
console.log('[plugin-unit] OK: transport injection position + asset route contract')
