// dsh-container 容器适配插件(运行期)。职责:
//   1. 会话 cookie 自举(替代旧 dsh-web.sh 的 token 交换);
//   2. 隐藏"打开配置文件"按钮: 容器无桌面, 上游 openSettingsDocument 无
//      headless 兜底(会 spawn 原生文本编辑器命令扑空)—— 让 settings/describe
//      报告 hasDocument:false, 浏览器侧 SettingsDocumentAction 按上游自身
//      逻辑(status !== 'ready' → 不渲染)让按钮整个消失, 不引入任何浏览器侧
//      代码。
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
// - 交换/写文件带短重试(与旧 dsh-web 的交换重试语义对齐), 瞬时失败不会
//   让 dsh-web 空等 120s 后 fail-fast;
// - cookie 原子写(tmp + rename), dsh-web 的 cat 永远读不到半截文件。
// 自举最终失败只记录日志、不阻止 dsh web 启动: dsh-web 侧会因等不到
// cookie 文件而 fail-fast, 与旧行为等价。
import { mkdir, readFile, rename, writeFile } from 'node:fs/promises'
import { join } from 'node:path'

export const name = 'dsh-container-adapt'
export const inject = ['webServer', 'connection', 'settings', 'settingsController']

/** dsh-web 约定存放会话 cookie 的目录(与 container/dsh-web.sh 一致)。 */
const RUNTIME_DIR = process.env.DSH_CADDY_RUNTIME_DIR ?? '/tmp/dsh-caddy'
const COOKIE_FILENAME = 'session-cookie'

/** 自举重试次数与间隔(覆盖端口就绪窗口与瞬时网络/写盘失败)。 */
const BOOTSTRAP_RETRIES = 5
const BOOTSTRAP_RETRY_DELAY_MS = 500

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
      // 1) 复用仍被 dsh 接受的旧 cookie(文件不存在/读取失败 → 走换取)。
      try {
        const existing = await readFile(cookieFile, 'utf8')
        if (existing !== '') {
          const probe = await fetch(`${baseUrl}/`, {
            headers: { cookie: existing },
            redirect: 'manual',
          })
          if (probe.status === 200) {
            console.log('[dsh-container-adapt] reusing the still-valid session cookie')
            return
          }
        }
      } catch {
        // 旧 cookie 不可用: 走换取流程。
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
}
