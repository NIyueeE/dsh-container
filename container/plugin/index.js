// dsh-container 容器适配插件(运行期)。职责:
//   1. 会话 cookie 自举(替代旧 dsh-web.sh 的 token 交换);
//   2. 隐藏"打开配置文件"按钮: 容器无桌面, 上游 openSettingsDocument 无
//      headless 兜底(会 spawn xdg-open 报 ENOENT)—— 把 settings provider
//      实例的 documentPath 置为 undefined, 上游 settings/describe 即返回
//      hasDocument:false, 浏览器侧 SettingsDocumentAction 按上游自身逻辑
//      (status !== 'ready' → 不渲染)让按钮整个消失, 不引入任何浏览器侧代码。
//
// 上游核对(dsh-v0.1.5-alpha.1):
//   - describe(): hasDocument = settings.documentPath !== undefined
//     (packages/api/settings-controller/src/index.ts), provider 即
//     ctx.get('settings') —— 本插件注入的 settings 服务;
//   - SettingsDocumentAction 仅在 describe 镜像报 hasDocument:true 时渲染
//     (packages/client/ui-settings-general/src/client/SettingsDocumentAction.tsx);
//   - prepareDocument 用 spec.filename(spec 是实例字段), 不受实例属性
//     遮蔽影响; agent-preset 的打开路径上游自带 {opened:false,path}
//     headless 回退(canOpenNativePath 在无桌面容器返回 false), 无需接管。
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
export const inject = ['webServer', 'connection', 'settings']

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

/** 挂载: 自举不阻塞插件激活(失败由 dsh-web 的等待超时兜底)。 */
export function apply(ctx) {
  // 1) 会话 cookie 自举。
  void bootstrap(ctx).catch((error) => {
    console.error(`[dsh-container-adapt] session bootstrap failed: ${error instanceof Error ? error.message : String(error)}`)
  })

  // 2) 隐藏"打开配置文件"按钮: 上游把 hasDocument 当作"本地文档可用"信号,
  //    只有它为真时 SettingsDocumentAction 才渲染。容器无桌面且该操作无
  //    headless 兜底, 直接以数据属性遮蔽 provider 原型上的 documentPath
  //    getter(spec.filename 不受影响, prepareDocument 照常), 按钮按上游
  //    自身逻辑消失, 不留下载端点。
  Object.defineProperty(ctx.settings, 'documentPath', { value: undefined })
}
