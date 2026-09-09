// dsh-container 容器适配插件(运行期)。职责:
//   1. 会话 cookie 自举(替代旧 dsh-web.sh 的 token 交换);
//   2. 设置 > 打开配置文件(settings/openSettingsDocument)降级: 容器无桌面,
//      上游会 spawn xdg-open 报 ENOENT —— 用 SettingsController 构造器
//      internals 注入把"原生打开"降级为带下载链接的友好提示;
//   3. /download/settings.yaml 下载端点(经 ctx.connection.requestRejection
//      套用上游的 Host/Origin + 浏览器会话鉴权)。
//
// 上游核对(dsh-v0.1.5-alpha.1): 产物打开已在 0.1.3+ 迁移到右侧栏预览
// (openFile → sidebarRight.openResource), 不再碰 xdg-open; 本插件只覆盖
// openSettingsDocument 这一条上游遗留的无门控原生打开路径。
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
import { SettingsController } from '/opt/deepseek-harness/packages/api/settings-controller/lib/index.js'

export const name = 'dsh-container-adapt'
export const inject = ['webServer', 'connection', 'settings']

/** dsh-web 约定存放会话 cookie 的目录(与 container/dsh-web.sh 一致)。 */
const RUNTIME_DIR = process.env.DSH_CADDY_RUNTIME_DIR ?? '/tmp/dsh-caddy'
const COOKIE_FILENAME = 'session-cookie'

/** 自举重试次数与间隔(覆盖端口就绪窗口与瞬时网络/写盘失败)。 */
const BOOTSTRAP_RETRIES = 5
const BOOTSTRAP_RETRY_DELAY_MS = 500

/** 设置文档下载端点(固定路径, 与文档/日志保持一致)。 */
const DOWNLOAD_PATH = '/download/settings.yaml'

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

/**
 * "原生打开"降级: 容器无桌面, 任何打开操作都指向下载端点。
 * 抛出的错误经上游 SettingsController 包装后显示在 UI toast,
 * 用户直接看到下载链接。
 */
function degradedOpen(path) {
  throw new Error(`no desktop in this container; the file was not opened. ` +
    `Download it at ${DOWNLOAD_PATH} (or edit it on the mounted volume at ${path})`)
}

/** 下载端点 handler: 套用上游鉴权后以 attachment 返回设置文档。 */
function downloadSettingsHandler(ctx) {
  return async (req, res) => {
    const rejection = ctx.connection.requestRejection(req)
    if (rejection !== undefined) {
      res.writeHead(rejection.status)
      res.end()
      return
    }
    const doc = ctx.settings?.documentPath
    if (doc === undefined) {
      res.writeHead(404)
      res.end('no settings document')
      return
    }
    let body
    try {
      body = await readFile(doc)
    } catch {
      res.writeHead(404)
      res.end('settings document not materialized yet; open Settings and save once, then retry')
      return
    }
    res.writeHead(200, {
      'content-type': 'application/yaml; charset=utf-8',
      'content-disposition': 'attachment; filename="settings.yaml"',
      'content-length': String(body.length),
      'cache-control': 'no-store',
    })
    res.end(body)
  }
}

/** 挂载: 自举不阻塞插件激活(失败由 dsh-web 的等待超时兜底)。 */
export function apply(ctx) {
  // 1) 会话 cookie 自举。
  void bootstrap(ctx).catch((error) => {
    console.error(`[dsh-container-adapt] session bootstrap failed: ${error instanceof Error ? error.message : String(error)}`)
  })

  // 2) 设置文档下载端点。
  ctx.webServer.register({
    kind: 'exact',
    path: DOWNLOAD_PATH,
    handler: downloadSettingsHandler(ctx),
  })

  // 3) 覆盖 settingsController(Cordis Service 构造时自动注册同名服务, 上游
  //    settings-controller 行已在 overlay 中 disabled, 本实例接管)。
  //    无桌面时"打开配置文件"不再 spawn xdg-open。
  new SettingsController(ctx, { nativeOpen: false }, {
    openPath: degradedOpen,
    openTextFile: degradedOpen,
    canOpenPath: () => false,
  })
}
