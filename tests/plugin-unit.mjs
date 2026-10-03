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

/** 收集 apply() 注册的 effect / 事件监听 / 路由处理器 / exporter, 并记录日志。 */
function createStubContext() {
  const effects = []
  const registrations = []
  const listeners = new Map()
  const exporters = []
  const logs = []
  const ctx = {
    webServer: {
      port: 3080,
      register: (route) => {
        registrations.push(route)
        return () => registrations.splice(registrations.indexOf(route), 1)
      },
    },
    connection: { authenticatedUrl: (url) => `${url}?token=stub` },
    settings: {},
    settingsController: { describe: () => ({ hasDocument: true }) },
    logger: {
      info: message => logs.push(['info', message]),
      warn: message => logs.push(['warn', message]),
      error: message => logs.push(['error', message]),
      exporter: (exporter) => {
        exporters.push(exporter)
        return () => exporters.splice(exporters.indexOf(exporter), 1)
      },
    },
    on: (event, handler) => {
      listeners.set(event, handler)
      return () => listeners.delete(event)
    },
    effect: (callback, label) => {
      const disposer = callback()
      effects.push({ label, disposer })
      return disposer
    },
  }
  return { ctx, effects, registrations, listeners, exporters, logs }
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
// 自举只读取这个 cookie 文件; 提前放一个"已被接受"的 cookie, 走复用路径(不发请求)。
await mkdir(join(scratch, 'caddy'), { recursive: true })
await writeFile(join(scratch, 'caddy', 'session-cookie'), 'dsh-auth-stub=value')

const { ctx, registrations, listeners, exporters, logs } = createStubContext()
const plugin = await import('../container/plugin/index.js')
assert.equal(plugin.name, 'dsh-container-adapt', 'plugin name changed')
assert.deepEqual(plugin.inject, ['webServer', 'connection', 'settings', 'settingsController'])

// Config 走 Standard Schema(Cordis resolveConfig 直接调 '~standard'.validate)。
assert.equal(plugin.Config['~standard'].version, 1, 'Config must be a Standard Schema v1 validator')
assert.deepEqual(plugin.Config['~standard'].validate(undefined), { value: { runtimeDir: '/tmp/dsh-caddy' } })
assert.deepEqual(plugin.Config['~standard'].validate({}), { value: { runtimeDir: '/tmp/dsh-caddy' } })
assert.deepEqual(plugin.Config['~standard'].validate({ runtimeDir: '/tmp/x' }), { value: { runtimeDir: '/tmp/x' } })
assert.ok(plugin.Config['~standard'].validate({ runtimeDir: 'relative/path' }).issues, 'relative runtimeDir must be rejected')
assert.ok(plugin.Config['~standard'].validate('nope').issues, 'non-object config must be rejected')

plugin.apply(ctx, { runtimeDir: join(scratch, 'caddy') })

assert.equal(registrations.length, 1, 'plugin must register exactly one web route')
assert.deepEqual(
  { kind: registrations[0].kind, path: registrations[0].path },
  { kind: 'prefix', path: '/container-assets' },
  'asset route must be the /container-assets prefix',
)

// 传输层声明: 推进行表的是上游的标准行类型(kind: 'global'), 而不是 tapIndex 字符串变换。
const injection = listeners.get('webserver/index-inject')
assert.equal(typeof injection, 'function', 'plugin must subscribe to webserver/index-inject')
const table = []
injection(table)
assert.deepEqual(
  table,
  [{ kind: 'global', name: '__DSH_TRANSPORT__', value: { ownsHost: true } }],
  'the transport declaration must be a structured global row',
)

// settings/describe 包装(遮蔽实例方法)与日志走 ctx.logger。
assert.equal(ctx.settingsController.describe().hasDocument, false, 'describe must report no local document')
assert.ok(logs.some(([, message]) => String(message).includes('describe wrapped')), 'wrap must be logged through ctx.logger')
assert.ok(
  logs.every(([, message]) => !String(message).startsWith('[dsh-container-adapt]')),
  'log lines must not carry a hand-written prefix (the logger owns it)',
)

// 本 profile 没有 console exporter, 插件必须自接一个且只导出自己的行 —— 否则
// docker logs / smoke 断言看不到任何插件日志。
assert.equal(exporters.length, 1, 'plugin must attach exactly one logger exporter')
const written = []
const originalWrite = process.stdout.write.bind(process.stdout)
process.stdout.write = chunk => { written.push(String(chunk)); return true }
try {
  exporters[0].export({ ts: 0, type: 'info', name: 'some-other-plugin', args: ['foreign line'] })
  exporters[0].export({ ts: 0, type: 'info', name: 'dsh-container-adapt', args: ['own line'] })
} finally {
  process.stdout.write = originalWrite
}
assert.deepEqual(
  written.map(line => line.includes('own line')),
  [true],
  'the exporter must forward this plugin\'s own lines and drop other plugins\' lines',
)

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
console.log('[plugin-unit] OK: structured transport row + Config + asset route contract')
