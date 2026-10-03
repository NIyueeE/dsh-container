// dsh-container 容器适配插件(运行期)。职责:
//   1. 会话 cookie 自举(替代旧 dsh-web.sh 的 token 交换);
//   2. 隐藏"打开配置文件"按钮: 容器无桌面, 上游 openSettingsDocument 无
//      headless 兜底(会 spawn 原生文本编辑器命令扑空)—— 让 settings/describe
//      报告 hasDocument:false, 浏览器侧 SettingsDocumentAction 按上游自身
//      逻辑(status !== 'ready' → 不渲染)让按钮整个消失, 不引入任何浏览器侧
//      代码;
//   3. 声明本页的传输层归属: 往服务端索引注入
//      __DSH_TRANSPORT__ = { ownsHost: true }。容器里的页面由 Caddy 反代提供,
//      代理已把 Host/Origin 改写成回环并注入会话 cookie —— 正是上游该契约描述的
//      "自己拥有 Host 的 shell"。上游唯一消费点是 connection 的 isLoopback,
//      置真后设置/凭据页在非回环 authority 上可用(替代旧的构建产物字符串补丁);
//   4. 提供构建期抽出的客户端图片(/container-assets/<内容哈希>.<ext>): 见
//      scripts/extract-inline-assets.js —— 上游把 8 张引导插画内联成 base64,
//      占合并包 49%, 抽成文件后只在真正进入该页时才请求。
//
// 上游核对(机制随版本演化, 两条路都保留):
//   - dsh-v0.1.7-alpha.1 起: settings-controller 的 describe() 硬编码
//     hasDocument: true, provider 接口(SettingsProvider → SettingsForms)已
//     删除 documentPath —— 翻 provider 属性失效, 改为包 settingsController
//     实例的 describe。Gateway 调远程方法是 invoke 期在实例上动态取值后再
//     Reflect.apply 带上 receiver(packages/api/gateway/src/index.ts), 实例
//     自有属性即遮蔽原型方法;
//   - 更早的 tag: describe 由 provider 的 documentPath 推导
//     (hasDocument = settings.documentPath !== undefined), 遮蔽该属性即可;
//   - 按钮渲染门两种版本一致: SettingsDocumentAction 仅在 store 由 describe
//     镜像推导出 status==='ready'(即 hasDocument:true)时渲染
//     (packages/client/ui-settings-general/src/client/SettingsDocumentAction.tsx
//     与 settings-document-store.ts);
//   - prepareDocument 用 spec.filename(spec 是实例字段), 不受实例属性
//     遮蔽影响; agent-preset 的打开路径上游自带 headless 回退
//     (canOpenNativePath 在无桌面容器返回 false), 无需接管。
//
// 幂等与稳健性:
// - 每次 dsh web 启动(含崩溃重启、dsh-restart)都会执行一次自举, 复用优先;
// - cookie 文件是状态而非事件: 内容 = 当前有效 cookie。复用成功不写盘, 只有
//   轮换/首次铸造才原子写(tmp + rename, dsh-web 的 cat 永远读不到半截文件);
//   dsh-web 以"文件是否存在 + 内容是否变化"收敛, 不依赖写入时机(无 mtime 握手);
// - 交换/写文件带短重试, 瞬时失败不会让 dsh-web 空等 120s 后 fail-fast;
// - 复用探测同样带短重试: 重启后新进程会话存储加载完成前可能拒绝旧 cookie,
//   多重探几次再决定重新铸造, 避免无谓轮换(纯优化: 即使误判, dsh-web 也会
//   按内容变化把新 cookie 收敛进 Caddy)。
// 自举最终失败只记录日志、不阻止 dsh web 启动: 文件缺失时 dsh-web 会在有界
// 等待后 fail-fast; 文件已存在时监督器继续用现有内容服务(不因一次自举失败
// 杀掉容器, 避免重启策略下的崩溃循环)。
import { createReadStream, existsSync } from 'node:fs'
import { mkdir, readFile, rename, stat, writeFile } from 'node:fs/promises'
import { join } from 'node:path'
import { pipeline } from 'node:stream/promises'

export const name = 'dsh-container-adapt'
export const inject = ['webServer', 'connection', 'settings', 'settingsController']

/** dsh-web 约定存放会话 cookie 的目录(与 container/dsh-web.sh 一致)。 */
const RUNTIME_DIR = process.env.DSH_CADDY_RUNTIME_DIR ?? '/tmp/dsh-caddy'
const COOKIE_FILENAME = 'session-cookie'

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

/** 自举重试次数与间隔(覆盖端口就绪窗口与瞬时网络/写盘失败)。 */
const BOOTSTRAP_RETRIES = 5
const BOOTSTRAP_RETRY_DELAY_MS = 500

/**
 * 复用探测重试: dsh web 重启后, 新进程的会话存储可能还在异步加载, 此时带旧
 * cookie 探测根路径可能拿到非 200(甚至连接被拒)。旧 cookie 本身仍有效(签名
 * 密钥在卷上持久化), 多重探几次再决定重新铸造 —— 否则无谓轮换 cookie,
 * Caddy 也要跟着重启, 浏览器侧已注入的会话全部作废。
 */
const PROBE_RETRIES = 3
const PROBE_DELAY_MS = 250

/**
 * 探测盘上的旧 cookie 是否仍被当前 dsh 进程接受(根路径 200 即可)。
 * 文件不存在/为空 → 没有可复用的 cookie, 直接返回 false。
 * @returns true 表示应复用(调用方负责记录日志)。
 */
async function reuseExistingCookie(baseUrl, cookieFile) {
  for (let probe = 1; probe <= PROBE_RETRIES; probe += 1) {
    let existing
    try {
      existing = await readFile(cookieFile, 'utf8')
    } catch {
      return false
    }
    if (existing === '') return false
    try {
      const response = await fetch(`${baseUrl}/`, {
        headers: { cookie: existing },
        redirect: 'manual',
      })
      if (response.status === 200) return true
      // 非 200: 启动瞬态(会话存储加载中)或 cookie 真失效, 重试后再判。
    } catch {
      // 连接失败(服务未就绪): 重试。
    }
    if (probe < PROBE_RETRIES) {
      await new Promise((resolve) => { setTimeout(resolve, PROBE_DELAY_MS) })
    }
  }
  return false
}

/** 从 Set-Cookie 头提取第一个 cookie 的 name=value(分号截断, 与旧 awk 一致)。 */
function firstCookieValue(setCookies) {
  for (const header of setCookies) {
    if (typeof header !== 'string') continue
    const pair = header.split(';', 1)[0]
    if (pair.includes('=')) return pair
  }
  return undefined
}

/** 原子写入: 先写 .tmp 再 rename, 读方永远拿到完整内容或旧内容。 */
async function writeCookieAtomically(cookieFile, cookie) {
  await mkdir(RUNTIME_DIR, { recursive: true, mode: 0o700 })
  const tmpFile = `${cookieFile}.tmp`
  await writeFile(tmpFile, cookie, { mode: 0o600 })
  await rename(tmpFile, cookieFile)
}

/**
 * 进程内自举: 优先复用仍被接受的旧 cookie, 否则用进程启动 token 换取。
 * 整体带短重试; 所有异常向上抛给调用方记录。
 * @param ctx - 注入 webServer/connection 的 Cordis 上下文。
 */
async function bootstrap(ctx) {
  const cookieFile = join(RUNTIME_DIR, COOKIE_FILENAME)
  const baseUrl = `http://127.0.0.1:${String(ctx.webServer.port)}`

  let lastError
  for (let attempt = 1; attempt <= BOOTSTRAP_RETRIES; attempt += 1) {
    try {
      // 1) 复用仍被 dsh 接受的旧 cookie(带短重试, 见 reuseExistingCookie)。
      //    复用成功不写盘: cookie 文件是**状态**(内容 = 当前有效 cookie), 不是
      //    事件。dsh-web 只在文件缺失时等待、只在内容变化时重建 Caddy 配置,
      //    所以这里绝不能为了让"写入被观察到"而重写同样的内容。
      if (await reuseExistingCookie(baseUrl, cookieFile)) {
        console.log('[dsh-container-adapt] reusing the still-valid session cookie')
        return
      }

      // 2) 用进程启动 token 换取会话 cookie。
      const tokenUrl = ctx.connection.authenticatedUrl(`${baseUrl}/`)
      const exchange = await fetch(tokenUrl, { redirect: 'manual' })
      const setCookies = typeof exchange.headers.getSetCookie === 'function'
        ? exchange.headers.getSetCookie()
        : [exchange.headers.get('set-cookie')].filter(Boolean)
      const cookie = firstCookieValue(setCookies)
      if (cookie === undefined) {
        throw new Error(`token exchange produced no session cookie (status ${String(exchange.status)})`)
      }

      // 3) 原子落盘。
      await writeCookieAtomically(cookieFile, cookie)
      console.log('[dsh-container-adapt] session cookie minted from the login token')
      return
    } catch (error) {
      lastError = error
      if (attempt < BOOTSTRAP_RETRIES) {
        await new Promise((resolve) => { setTimeout(resolve, BOOTSTRAP_RETRY_DELAY_MS) })
      }
    }
  }
  throw lastError ?? new Error('session bootstrap failed')
}

/** describe 包装标记: 保证多次 apply(dsh web 每次启动/重启)幂等。 */
const DESCRIBE_WRAPPED = Symbol.for('dsh-container-adapt.describeWrapped')

/**
 * 强制 settings/describe 报告 hasDocument:false —— v0.1.7+ 上游已把它写死
 * 成 true, provider 侧无属性可翻, 只能包 controller 实例的 describe。
 * Gateway 调用路径: Reflect.get(callReceiver, 'describe') 取到的是实例自有
 * 属性(遮蔽原型方法), 再 Reflect.apply(method, receiver, args) 调用 —— 所以
 * 这里用普通函数 + apply 转发, this 与参数都保持原样。
 * @param controller - settingsController 服务实例(dsh-web profile 必有;
 *    缺失时静默跳过, 不阻塞插件其余职责)。
 */
function forceNoSettingsDocument(controller) {
  if (controller === undefined) return
  const original = controller.describe
  if (typeof original !== 'function' || original[DESCRIBE_WRAPPED]) return
  const wrapped = function describeWithoutDocument() {
    return { ...original.apply(this, arguments), hasDocument: false }
  }
  Object.defineProperty(wrapped, DESCRIBE_WRAPPED, { value: true })
  Object.defineProperty(controller, 'describe', { value: wrapped, configurable: true })
  console.log('[dsh-container-adapt] settings describe wrapped: hasDocument forced to false')
}

/**
 * 注入传输层归属声明。上游契约(packages/client/connection/src/client/index.ts):
 * `__DSH_TRANSPORT__` 由"自己拥有 Host 的 shell"设置, 唯一消费点是
 * `isLoopback: transport?.ownsHost === true || …`; 上游桌面 shell
 * (apps/web/src/main.ts)与 worker 预览页(experimental/webworker-runtime)都这么用。
 * 本容器里 Caddy 代理就是那个 shell(改写 Host/Origin + 注入会话 cookie), 置真后
 * 设置/凭据页在非回环 authority 上可用 —— 取代旧的构建产物字符串补丁。
 *
 * 纯 html→html 变换(tapIndex 契约): 插在 <head> 之后, 内联脚本先于
 * `type="module"` 的 bundle 执行, connection 插件 apply 时已能读到。找不到
 * <head> 时原样返回(上游若改文档结构则退化成"没注入", 由 smoke 断言发现)。
 * @param {string} html - 服务端渲染出的索引 HTML。
 * @returns {string} 注入后的 HTML。
 */
function injectTransportGlobal(html) {
  const at = html.indexOf('<head>')
  if (at === -1) return html
  return `${html.slice(0, at + 6)}<script>globalThis.__DSH_TRANSPORT__={ownsHost:true}</script>${html.slice(at + 6)}`
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

/** 挂载: 自举不阻塞插件激活(失败由 dsh-web 的等待超时兜底)。 */
export function apply(ctx) {
  // 1) 会话 cookie 自举。
  void bootstrap(ctx).catch((error) => {
    console.error(`[dsh-container-adapt] session bootstrap failed: ${error instanceof Error ? error.message : String(error)}`)
  })

  // 2) 隐藏"打开配置文件"按钮: 上游把 hasDocument 当作"本地文档可用"信号,
  //    只有它为真时 SettingsDocumentAction 才渲染。容器无桌面且该操作无
  //    headless 兜底。两条路并存(见文件头"上游核对"):
  //    - 旧 tag: describe 由 provider.documentPath 推导, 遮蔽该属性
  //      (spec.filename 不受影响, prepareDocument 照常);
  //    - v0.1.7+: describe 硬编码 true, 包 controller 实例的 describe。
  if ('documentPath' in ctx.settings) {
    Object.defineProperty(ctx.settings, 'documentPath', { value: undefined })
  }
  forceNoSettingsDocument(ctx.settingsController)

  // 3) 传输层声明与抽图路由都注册为 effect: webServer.register()/tapIndex() 都
  //    返回 disposer, 插件卸载时自动撤销(上游 gateway 注册 mux 路由同款写法)。
  ctx.effect(
    () => ctx.webServer.tapIndex(injectTransportGlobal),
    'container-adapt: __DSH_TRANSPORT__ ownsHost injection',
  )
  if (!existsSync(ASSET_DIR)) {
    console.warn(`[dsh-container-adapt] ${ASSET_DIR} is missing; extracted client images will 404`)
  }
  ctx.effect(
    () => ctx.webServer.register({ kind: 'prefix', path: ASSET_ROUTE, handler: createAssetHandler() }),
    'container-adapt: extracted client image route',
  )
}
