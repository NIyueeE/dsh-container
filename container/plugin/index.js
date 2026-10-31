// dsh-container 容器适配插件(运行期)。职责:
//   1. 把 dsh 进程的 launch token 写到 /tmp/dsh-caddy/launch-token, 供 Caddy 在
//      浏览器首次访问 / 时 302 到 /?token=...; 浏览器随后从 dsh 拿到
//      HttpOnly/SameSite=Strict 会话 cookie 并自己持有 —— 容器不再注入 cookie,
//      也不改写 Host/Origin;
//   2. 隐藏"打开配置文件"按钮: 容器无桌面, 上游 openSettingsDocument 无
//      headless 兜底(会 spawn 原生文本编辑器命令扑空)—— 让 settings/describe
//      报告 hasDocument:false, 浏览器侧 SettingsDocumentAction 按上游自身逻辑
//      (status !== 'ready' → 不渲染)让按钮整个消失, 不引入任何浏览器侧代码;
//   3. 提供构建期抽出的客户端图片(/container-assets/<内容哈希>.<ext>): 见
//      scripts/extract-inline-assets.js —— 上游把 8 张引导插画内联成 base64,
//      占合并包 49%, 抽成文件后只在真正进入该页时才请求。
//
// 遵循上游插件规范: 导出 name/inject/apply/Config; 只用 inject 声明过的服务;
// 资源注册走 ctx.effect 的 disposer; 日志走 ctx.logger; 实例级可变参数是
// Config 字段(从 overlay 条目的 config 传入), 不读环境变量。
//
// 上游核对:
//   - Connection.authenticatedUrl() 返回带进程 launch token 的 URL; token 只用于
//     首次浏览器登录, 不再在插件内 curl 交换 cookie;
//   - dsh 的浏览器会话 cookie 由 Connection 在 index token 交换时 Set-Cookie,
//     天然带 HttpOnly/SameSite=Strict, 并绑定浏览器实际使用的 authority;
//   - dsh 的 Host/Origin 围栏原样生效: 外部 authority 由 dsh-web 的
//     --trusted-host 授权, Caddy 只转发, 不改写;
//   - settings-controller 的 describe() 硬编码 hasDocument: true —— 没有
//     provider 侧属性可翻, 只能包 settingsController 实例的 describe。
//     Gateway 调远程方法是 invoke 期在实例上动态取值后再 Reflect.apply 带上
//     receiver(packages/api/gateway/src/index.ts), 实例自有属性即遮蔽原型
//     方法;
//   - 按钮渲染门: SettingsDocumentAction 仅在 store 由 describe 镜像推导出
//     status==='ready'(即 hasDocument:true)时渲染。
//
// 幂等与稳健性:
// - 每次 dsh web 启动(含崩溃重启、dsh-restart)都会重新写一次 token;
// - token 文件是状态而非事件: 内容 = 当前进程的 launch token; 原子写
//   (tmp + rename), dsh-web 的 cat 永远读不到半截文件;
// - 写文件带短重试, 瞬时失败不会让 dsh-web 空等 120s 后 fail-fast;
// - 自举最终失败只记录日志、不阻止 dsh web 启动: 文件缺失时 dsh-web 会在有界
//   等待后 fail-fast; 文件已存在时监督器继续用现有内容服务(不因一次写失败
//   杀掉容器, 避免重启策略下的崩溃循环)。浏览器仍可直接打开 dsh 打印的
//   token URL 登录, 不依赖这个重定向。
import { randomUUID } from 'node:crypto'
import { createReadStream, existsSync } from 'node:fs'
import { mkdir, rename, rm, stat, writeFile } from 'node:fs/promises'
import { dirname, join } from 'node:path'
import { pipeline } from 'node:stream/promises'

export const name = 'dsh-container-adapt'
export const inject = ['webServer', 'connection', 'settingsController']

/**
 * launch token 状态文件所在目录: 默认值与 `container/dsh-web.sh` 的 `RUNTIME_DIR`
 * 共享(监督器从同一路径读取)。它是**实例级**参数而非部署配置 —— 需要跑隔离实例
 * (本机验证第二个 dsh web)时, 在 overlay 条目的 `config:` 里覆写, 而不是靠环境
 * 变量: 上游规则明确"a `DEFAULT_*` constant or test hook is not configurability",
 * 可变的实例参数应当是可校验的 `Config` 字段。
 * 注意: 覆写它必须同时改 `dsh-web.sh` 的 `RUNTIME_DIR`, 否则监督器等不到 token
 * 文件会在有界等待后 fail-fast(这也是正式部署不传 config 的原因)。
 */
const DEFAULT_RUNTIME_DIR = '/tmp/dsh-caddy'
const TOKEN_FILENAME = 'launch-token'

/** launch token 只允许 Caddyfile 安全的 URL-safe 字符; 上游 token 是 base64url。 */
const TOKEN_PATTERN = /^[A-Za-z0-9_-]+$/

/**
 * 插件配置。Cordis 用 Standard Schema 校验(`resolveConfig()` 调
 * `Config['~standard'].validate(config)`), 因此这里手写校验器即可, 插件不必
 * 引入 schemastery 依赖(它只被 `--patch` 按绝对路径加载, 没有自己的 node_modules)。
 */
export const Config = {
  '~standard': {
    version: 1,
    vendor: 'dsh-container',
    /**
     * 校验并补默认值。
     * @param value - overlay 条目 `config:` 里的原始值(缺省时是 undefined)。
     * @returns 校验后的配置, 或 Standard Schema 的 issues 列表。
     */
    validate(value) {
      if (value !== undefined && (typeof value !== 'object' || value === null || Array.isArray(value))) {
        return { issues: [{ message: 'dsh-container-adapt config must be an object' }] }
      }
      const runtimeDir = value?.runtimeDir ?? DEFAULT_RUNTIME_DIR
      if (typeof runtimeDir !== 'string' || !runtimeDir.startsWith('/')) {
        return { issues: [{ message: 'runtimeDir must be an absolute path' }] }
      }
      return { value: { runtimeDir } }
    },
  },
}

/** 抽图产物目录与路由前缀(与 scripts/extract-inline-assets.js 的默认输出一致, 镜像布局固定)。 */
const ASSET_ROUTE = '/container-assets'
const ASSET_DIR = '/opt/dsh-container-plugin/assets'

/** 只接受抽图脚本写出的内容哈希文件名 —— 这条正则本身就是路径穿越防护。 */
const ASSET_NAME = /^[0-9a-f]{16,64}\.(?:png|jpe?g|webp|gif)$/
const ASSET_TYPES = {
  png: 'image/png',
  jpg: 'image/jpeg',
  jpeg: 'image/jpeg',
  webp: 'image/webp',
  gif: 'image/gif',
}
const ASSET_CACHE_CONTROL = 'public, max-age=31536000, immutable'

/** token 写入重试次数与间隔(覆盖启动瞬间 connection 尚未就绪的窗口)。 */
const WRITE_RETRIES = 5
const WRITE_RETRY_DELAY_MS = 500

/**
 * 原子写入: 先写同目录唯一临时文件再 rename, 读方永远拿到完整内容或旧内容。
 * 临时名必须唯一: 同一进程内重复 apply/并发写同一个 token 文件时, 固定
 * `.tmp` 会让两个写者互相 rename 对方的半成品。无论成功失败都清理临时文件。
 */
async function writeFileAtomically(file, content) {
  await mkdir(dirname(file), { recursive: true, mode: 0o700 })
  const tmpFile = `${file}.${process.pid}.${randomUUID()}.tmp`
  try {
    await writeFile(tmpFile, content, { mode: 0o600, flag: 'wx' })
    await rename(tmpFile, file)
  } finally {
    await rm(tmpFile, { force: true })
  }
}

/**
 * 把当前进程的 launch token 写到 Caddy 读取的状态文件。浏览器首次访问 / 时,
 * Caddy 302 到 /?token=<token>; dsh 在 index 交换中给浏览器 Set-Cookie, 之后
 * 浏览器自己携带会话 cookie。插件不再发 HTTP 请求, 也不再碰 cookie。
 * @param ctx - 注入 webServer/connection 的 Cordis 上下文。
 * @param tokenFile - launch token 状态文件路径(由 config.runtimeDir 决定)。
 */
async function writeLaunchToken(ctx, tokenFile) {
  let lastError
  for (let attempt = 1; attempt <= WRITE_RETRIES; attempt += 1) {
    try {
      const authenticated = ctx.connection.authenticatedUrl(`http://127.0.0.1:${String(ctx.webServer.port)}/`)
      const token = new URL(authenticated).searchParams.get('token')
      if (token === null || !TOKEN_PATTERN.test(token)) {
        throw new Error('connection.authenticatedUrl() did not yield a URL-safe launch token')
      }
      await writeFileAtomically(tokenFile, token)
      ctx.logger.info('launch token written for the proxy login redirect')
      return
    } catch (error) {
      lastError = error
      if (attempt < WRITE_RETRIES) {
        await new Promise((resolve) => { setTimeout(resolve, WRITE_RETRY_DELAY_MS) })
      }
    }
  }
  throw lastError ?? new Error('launch token write failed')
}

/** describe 包装标记: 保证多次 apply(dsh web 每次启动/重启)幂等。 */
const DESCRIBE_WRAPPED = Symbol.for('dsh-container-adapt.describeWrapped')

/**
 * 日志可见性: 本镜像的 web profile 没有挂载 console exporter(vendored 的
 * `@deepseek-ai/cordis-plugin-logger-console` 没有出现在任何 bundle 里), 因此
 * `ctx.logger` 默认**什么都不输出**。而本镜像的运维面依赖这些行: dsh-web 把 dsh 的
 * stdout 镜像进容器日志、smoke 断言据此判断 token 写入成功、docs 的排障步骤也指向它。
 * 这里用上游标准 API `ctx.logger.exporter()`(AppBoot 也这么接诊断 exporter)注册一个
 * **只导出本插件日志**的 exporter —— 按 `message.name` 过滤, 不改动其它插件的输出;
 * 调用点仍然全部走 `ctx.logger`。
 * @param ctx - 插件上下文(其 logger 暴露 exporter 注册, disposer 随 fiber 自动撤销)。
 */
function exportOwnLogs(ctx) {
  ctx.logger.exporter({
    export: (message) => {
      if (message.name !== name) return
      const detail = message.args
        .map((arg) => (arg instanceof Error ? arg.message : typeof arg === 'string' ? arg : JSON.stringify(arg)))
        .join(' ')
      process.stdout.write(`${new Date(message.ts).toISOString()} [${String(message.type)}] ${message.name}: ${detail}\n`)
    },
  })
}

/**
 * 强制 settings/describe 报告 hasDocument:false —— 上游把它写死成 true,
 * provider 侧没有可翻的属性。
 *
 * 为什么是"遮蔽实例方法"这种写法: Cordis 没有"只改一个方法返回值"的标准入口 ——
 * `ctx.intercept(name, config)` 只合并**服务配置**(不碰实现), `reflect.set(name,
 * value)` 明确要求"调用方自己的 fiber 提供过该服务"(源码: `impl.fiber !==
 * this.ctx.fiber` → throw "cannot set property ... in multiple fibers"), 而
 * settingsController 由上游插件提供; 客户端渲染门也只读 describe 的
 * `hasDocument`(SettingsDocumentAction: `status !== 'ready'` → 不渲染), 没有可注入
 * 的客户端能力位。因此最小可行的偏离就是遮蔽这一个方法 —— 它成立是因为 Gateway
 * 在 invoke 期动态取值再 `Reflect.apply`(见 packages/api/gateway/src/index.ts),
 * 而不是靠实例属性缓存。上游一旦给出配置开关/headless 兜底, 这里就删掉
 * (docs/upstream-contract.md § Simplification triggers)。
 *
 * @param controller - settingsController 服务实例(dsh-web profile 必有;
 *    缺失时静默跳过, 不阻塞插件其余职责)。
 * @param logger - 插件 ctx 的 logger。
 */
function forceNoSettingsDocument(controller, logger) {
  if (controller === undefined) return
  const original = controller.describe
  if (typeof original !== 'function' || original[DESCRIBE_WRAPPED]) return
  const wrapped = function describeWithoutDocument() {
    return { ...original.apply(this, arguments), hasDocument: false }
  }
  Object.defineProperty(wrapped, DESCRIBE_WRAPPED, { value: true })
  Object.defineProperty(controller, 'describe', { value: wrapped, configurable: true })
  logger.info('settings describe wrapped: hasDocument forced to false')
}

/**
 * 提供构建期抽出的客户端图片(见 scripts/extract-inline-assets.js)。只认内容哈希
 * 文件名, 命中即流式返回整文件并带 immutable 缓存头(与 dsh 给 /plugins/* 的策略
 * 一致); 图片本身是压缩格式, webserver 的 gzip 中间件按 content-type 跳过。
 * @returns {(req: object, res: object) => Promise<void>} webServer 前缀路由处理器。
 */
function createAssetHandler() {
  return async (req, res) => {
    const path = new URL(req.url ?? '/', 'http://container-assets').pathname.slice(ASSET_ROUTE.length + 1)
    if (!ASSET_NAME.test(path)) {
      res.writeHead(404, { 'content-type': 'text/plain; charset=utf-8' }).end('not found')
      return
    }
    const file = join(ASSET_DIR, path)
    try {
      const info = await stat(file)
      res.writeHead(200, {
        'content-type': ASSET_TYPES[path.slice(path.lastIndexOf('.') + 1).toLowerCase()],
        'content-length': info.size,
        'cache-control': ASSET_CACHE_CONTROL,
      })
      await pipeline(createReadStream(file), res)
    } catch {
      res.writeHead(404, { 'content-type': 'text/plain; charset=utf-8' }).end('not found')
    }
  }
}

/** 挂载: token 写入不阻塞插件激活(失败由 dsh-web 的等待超时兜底)。 */
export function apply(ctx, config) {
  // 0) 日志可见性: 本 profile 无 console exporter, 自接一个(只导出本插件日志)。
  exportOwnLogs(ctx)

  // 1) 把 launch token 交给 Caddy 的登录重定向。
  void writeLaunchToken(ctx, join(config.runtimeDir, TOKEN_FILENAME)).catch((error) => {
    ctx.logger.error(`launch token write failed: ${error instanceof Error ? error.message : String(error)}`)
  })

  // 2) 隐藏"打开配置文件"按钮: 上游把 hasDocument 当作"本地文档可用"信号,
  //    只有它为真时 SettingsDocumentAction 才渲染。容器无桌面且该操作无
  //    headless 兜底, 因此包 controller 实例的 describe(见文件头"上游核对")。
  forceNoSettingsDocument(ctx.settingsController, ctx.logger)

  // 3) 抽图路由: webServer.register() 返回 disposer, 用 ctx.effect 登记
  //    (上游 gateway 注册 mux 路由同款写法)。
  if (!existsSync(ASSET_DIR)) {
    ctx.logger.warn(`${ASSET_DIR} is missing; extracted client images will 404`)
  }
  ctx.effect(
    () => ctx.webServer.register({ kind: 'prefix', path: ASSET_ROUTE, handler: createAssetHandler() }),
    'container-adapt: extracted client image route',
  )
}
