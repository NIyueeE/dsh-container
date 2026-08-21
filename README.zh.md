# dsh 容器镜像

[DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness)(`dsh`)的容器化镜像,基于精简的
`debian:13-slim` 基础镜像,只保留本项目需要的工具链:Node.js LTS、pnpm、uv、Rust/cargo、Caddy、
podman、GitHub CLI。开箱即用,支持 **可选的 dsh 自动更新**。镜像发布在 GitHub Container Registry,
`compose.yaml` 与 Quadlet `.container` 示例均直接拉取镜像,不本地构建。

DSH 本体来自官方仓库 [deepseek-ai/deepseek-harness](https://github.com/deepseek-ai/deepseek-harness),
安装方式遵循官方 README:安装 Node.js 后通过 npm 安装 `@deepseek-ai/dsh`。

## 特性

| 组件 | 说明 |
|---|---|
| 基础镜像 | `debian:13-slim`(精简,可用 `BASE_IMAGE` 构建参数覆盖) |
| 自带工具链 | Node.js 22 LTS、pnpm、uv、Rust/cargo、git、build-essential、Caddy、podman、gh |
| 补装用户级工具 | Rust/cargo(`~/.rustup` + `~/.cargo`)、uv(`~/.local/bin`)、pnpm(`~/.local/share/pnpm`)——随 `/home/dsh` 持久化 |
| 容器开发工具 | podman(apt),已配置 rootless subuid/subgid 映射;嵌套 rootless 是否可用取决于宿主运行时 |
| dsh | npm 全局安装 `@deepseek-ai/dsh`,与官方 README 的 `npx @deepseek-ai/dsh web` 同源;`DSH_VERSION` 可固定 |
| 自动更新 | 默认关闭(`DSH_AUTO_UPDATE=0`);设 `1` 后容器启动时把 dsh 更新到 npm 最新版(只升不降,不会把固定版本降级);镜像本身支持 `Pull=newer` / `AutoUpdate=registry` |
| dsh web 守护 | `dsh web` 由 `dsh-web` 守护脚本托管,退出/崩溃后自动重启;容器内执行 `dsh-restart` 可在不重启容器的情况下手动重启 dsh web |
| 对外暴露 | Caddy 反向代理(`0.0.0.0:3081` → dsh 的 `127.0.0.1:3080`),把 `Host`/`Origin` 改写为回环并对 UI 资源做 gzip 压缩(约 1.3MB → 约 360KB);可用 `DSH_PROXY_USER` / `DSH_PROXY_PASSWORD` 启用 basic auth |
| 远程设置兼容 | 每次 `dsh web` 启动前应用幂等的前端补丁:远程浏览器经代理可使用设置/凭据,并注入 `crypto.randomUUID` polyfill,纯 HTTP 内网也能工作 |
| 可观测性 | OCI labels(`org.opencontainers.image.*` 含 git revision)、`HEALTHCHECK`(curl 3080 + 3081) |
| 运行时用户 | uid 1000(`dsh`);`/home/dsh` 是持久化用户层,`dsh` 拥有免密 sudo |

基础镜像默认固定;dsh 顶层版本与 Rust 工具链可用 `--build-arg` 固定。uv/pnpm 安装为用户级工具,
Caddy/podman/gh 来自 apt —— 详见 [build.md](docs/build.md)。

## 环境变量

| 变量 | 默认 | 说明 |
|---|---|---|
| `DSH_PROXY_USER` / `DSH_PROXY_PASSWORD` | *(空)* | 启用对外代理的 basic auth(建议启用):不启用时,能访问 3081 端口的任何人都可以驱动代理**并**读取/修改全部设置与凭据(见 [security.md](docs/security.md) 安全边界一节)。两个变量必须同时设置或同时为空,只设置一个时入口脚本会拒绝启动 |
| `DSH_AUTO_UPDATE` | `0` | 设为 `1` 时容器启动时自动更新 dsh 到 npm 最新版;离线或失败时沿用镜像内版本 |

其余全部使用内置默认值:

- dsh 数据:`~/.dsh`(`/home/dsh/.dsh`)——上游默认,不设置 `DSH_HOME`
- 工作目录:`$HOME`(`/home/dsh`);dsh 按需在其中创建目录
- Rust/cargo:`~/.rustup` + `~/.cargo`
- uv:`~/.local/bin`(托管的 Python/tool 数据在 `~/.local/share/uv`)
- pnpm:`~/.local/share/pnpm`

持久化边界是**整个 `/home/dsh`**:把它挂载为一个卷,用户层状态在镜像升级后保留,
`/usr/local` 等系统层随新镜像重置。Rust/uv/pnpm/dsh 等用户级工具已打进镜像,首次使用空命名卷时
会复制进卷;之后通过 `sudo apt` 安装的系统包位于容器/系统层,不属于持久化 home 卷。

对外端口为 `3081`:容器内 **Caddy 反向代理**监听 `0.0.0.0:3081`,把 `Host`/`Origin` 改写为
回环后转发到 `dsh web` 的 `127.0.0.1:3080`。代理对 UI 资源做 gzip 压缩(约 1.3MB → 约
360KB),远端访问时尤其明显;SSE/WebSocket 流式响应不缓冲、即时转发(已在 Caddy 2.6 上验证),
agent 输出不会被代理延迟。如需跨公网访问,建议在 3081 前用外置反向代理终止 TLS;该代理必须
转发 WebSocket 升级头(nginx 为 `proxy_set_header Upgrade $http_upgrade` /
`proxy_set_header Connection "upgrade"`),且不要缓冲或超时掐断空闲流 —— 完整示例见
[deployment.md](docs/deployment.md)。dsh 的 `/api` 浏览器信任围栏只检查 HTTP 头,因此
远程浏览器能通过全部接口 —— 包括设置/凭据等原本仅回环放行的方法。**代理因此成为安全边界**:
能访问 3081 的人即拥有完全控制权,请启用 `DSH_PROXY_USER`/`DSH_PROXY_PASSWORD` 并用防火墙
收口端口。上游 dsh 的浏览器代码仍按 `window.location.hostname` 限制设置/凭据页面,因此本镜像
会在每次 `dsh web` 启动前应用一个幂等的前端补丁:把经代理的远程浏览器视为回环,并注入
`crypto.randomUUID` polyfill 以兼容纯 HTTP 内网。若上游 dsh 版本改变了 bundle 字符串,补丁会
警告并跳过,而不是阻止启动。`dsh web` 的附加参数可通过容器 `command` 透传,例如
`["--port", "8080"]`(只改 dsh 内部端口,对外端口仍是 3081)。

容器内 `dsh web` 由 `dsh-web` 守护:如果退出或崩溃会自动重新拉起。需要在不重启容器的情况下
手动重启 dsh web,可执行:

```sh
docker exec dsh dsh-restart
```

## 快速开始

### Docker Compose(Linux)

```bash
docker compose -f examples/compose.yaml up -d
# 打开 http://127.0.0.1:3081
```

### Podman Quadlet(Linux,推荐)

```bash
sudo mkdir -p /etc/containers/systemd
sudo cp examples/dsh.container /etc/containers/systemd/
sudo systemctl daemon-reload
sudo systemctl enable --now dsh.service
```

> **持久化** — 两个示例都把同一个卷挂载到 `/home/dsh`。这是用户层:
> `~/.dsh`、`~/.cargo`、npm/缓存/配置文件、dsh 按需创建的工作目录以及用户安装的工具在镜像升级后保留;
> 系统层(`/usr/local`、apt 包)来自新镜像。

> **网络** — `dsh web` 监听 `127.0.0.1`(npm 发布版拒绝 `--host 0.0.0.0`);入口脚本用 Caddy
> 反向代理监听 `0.0.0.0:3081`,把 `Host`/`Origin` 改写为回环后转发到 dsh 的 `127.0.0.1:3080`,
> 因此两个编排示例都可以用普通桥接网络并发布端口 `3081`。详见 [security.md](docs/security.md)
> 与[部署指南](docs/deployment.md)。

## 文档

| 文档 | 内容 |
|---|---|
| [docs/deployment.md](docs/deployment.md) | 部署与维护:前置条件、Compose、Quadlet、自动更新、远程访问、离线使用、常见问题 |
| [docs/security.md](docs/security.md) | 安全注意事项:网络暴露权衡、凭据安全、可信工作负载 |
| [docs/build.md](docs/build.md) | 构建配置:构建参数、版本固定、可复现构建 |
| [docs/releasing.md](docs/releasing.md) | 镜像标签、发布流程(GitHub Release + 版本号对齐)、镜像清理 |
| [docs/design.md](docs/design.md) | 设计参考与相关项目 |
| [docs/development.md](docs/development.md) | 目录结构与本地开发 |

## License

[MIT](LICENSE)
