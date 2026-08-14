# dsh 容器镜像

[DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness)(`dsh`)的容器化镜像,基于微软通用开发容器镜像
[`mcr.microsoft.com/devcontainers/universal`](https://mcr.microsoft.com/en-us/artifact/mcr/devcontainers/universal/about),
开箱即用,支持 **dsh 自动更新**。镜像发布在 GitHub Container Registry,
`compose.yaml` 与 Quadlet `.container` 示例均直接拉取镜像,不本地构建。

DSH 本体来自官方仓库 [deepseek-ai/deepseek-harness](https://github.com/deepseek-ai/deepseek-harness),
安装方式遵循官方 README:安装 Node.js 后通过 npm 安装 `@deepseek-ai/dsh`。

## 特性

| 组件 | 说明 |
|---|---|
| 基础镜像 | `mcr.microsoft.com/devcontainers/universal:latest`(Ubuntu 24.04,体积大但工具链齐全;当前与 `6.1.1-noble` 同 digest;可用 `BASE_IMAGE` 构建参数固定精确 tag) |
| 自带工具链 | Node.js 22/24(nvm)、Python、Go、Java、Docker CLI/Engine、git、build-essential 等 |
| 补装工具链 | Rust/cargo(rustup minimal profile,`RUST_TOOLCHAIN` 可固定)、uv(从官方镜像 COPY 固定版本,默认 0.12.3) |
| dsh | npm 全局安装 `@deepseek-ai/dsh`,与官方 README 的 `npx @deepseek-ai/dsh web` 同源;`DSH_VERSION` 可固定 |
| 自动更新 | 容器启动时自动把 dsh 更新到 npm 最新版(可关闭);镜像本身支持 `Pull=newer` / `AutoUpdate=registry` |
| 对外暴露 | Caddy 反向代理(`0.0.0.0:3081` → dsh 的 `127.0.0.1:3080`),把 `Host`/`Origin` 改写为回环并对 UI 资源做 gzip 压缩(约 1.3MB → 约 360KB);可用 `DSH_PROXY_USER` / `DSH_PROXY_PASSWORD` 启用 basic auth |
| 可观测性 | OCI labels(`org.opencontainers.image.*` 含 git revision)、`HEALTHCHECK`(curl 3080 + 3081) |
| 运行时用户 | uid 1000(universal 6.x 为 `codespace`,旧版 2.x 为 `vscode`,自动兼容) |

全部可变组件(基础镜像/dsh/rust/uv)均可用 `--build-arg` 固定版本,
构建参数见 [build.md](docs/build.md)。

## 环境变量

| 变量 | 默认 | 说明 |
|---|---|---|
| `DSH_HOME` | `$HOME/dsh` | dsh 数据目录(profiles / sessions / 插件),由入口脚本按运行时用户 home 解析(universal 6.x 即 `/home/codespace/dsh`),建议挂载持久化卷 |
| `DSH_WORKSPACE` | `$HOME/workspace` | 任务工作区,入口脚本自动创建并以此为工作目录(universal 6.x 即 `/home/codespace/workspace`) |
| `DSH_PROXY_USER` / `DSH_PROXY_PASSWORD` | *(空)* | 启用对外代理的 basic auth(建议启用):不启用时,能访问 3081 端口的任何人都可以驱动代理**并**读取/修改全部设置与凭据(见 [security.md](docs/security.md) 安全边界一节) |
| `DSH_AUTO_UPDATE` | `1` | 容器启动时自动更新 dsh 到 npm 最新版;离线或失败时沿用镜像内版本 |
| `DSH_UPDATE_ONLY` | `0` | 设为 `1` 时只执行 dsh 更新并退出(供 timer/cron 定时更新) |

对外端口为 `3081`:容器内 **Caddy 反向代理**监听 `0.0.0.0:3081`,把 `Host`/`Origin` 改写为
回环后转发到 `dsh web` 的 `127.0.0.1:3080`。代理对 UI 资源做 gzip 压缩(约 1.3MB → 约
360KB),远端访问时尤其明显;SSE/WebSocket 流式响应不缓冲、即时转发(已在 Caddy 2.6 上验证),
agent 输出不会被代理延迟。dsh 的 `/api` 浏览器信任围栏只检查 HTTP 头,因此
远程浏览器能通过全部接口 —— 包括设置/凭据等原本仅回环放行的方法。**代理因此成为安全边界**:
能访问 3081 的人即拥有完全控制权,请启用 `DSH_PROXY_USER`/`DSH_PROXY_PASSWORD` 并用防火墙
收口端口。`dsh web` 的附加参数可通过容器 `command` 透传,例如 `["--port", "8080"]`(只改
dsh 内部端口,对外端口仍是 3081)。

## 快速开始

### Docker Compose(Linux)

```bash
mkdir -p workspace && sudo chown -R 1000:1000 workspace   # 工作区属主对齐容器用户
docker compose -f examples/compose.yaml up -d
# 打开 http://127.0.0.1:3081
```

### Podman Quadlet(Linux,推荐)

```bash
sudo mkdir -p /etc/containers/systemd
sudo cp examples/dsh.container /etc/containers/systemd/
# 按需修改 examples/dsh.container 中的工作区路径
sudo systemctl daemon-reload
sudo systemctl enable --now dsh.service
```

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
| [docs/releasing.md](docs/releasing.md) | 镜像标签、发布流程(GitHub Release + 版本号对齐)、首次发布手动步骤 |
| [docs/design.md](docs/design.md) | 设计参考与相关项目 |
| [docs/development.md](docs/development.md) | 目录结构与本地开发 |

## License

[MIT](LICENSE)
