<div align="center">

# dsh Container Image

**[DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness)(`dsh`)的开箱即用容器——agent、完整工具链与反向代理集成于一个镜像,基于官方源码 tag 构建。**

[![Release](https://img.shields.io/github/v/tag/NIyueeE/dsh-container?filter=dsh-v*&label=release&sort=semver)](https://github.com/NIyueeE/dsh-container/releases)
[![CI](https://img.shields.io/github/actions/workflow/status/NIyueeE/dsh-container/image.yml?branch=main&label=CI)](https://github.com/NIyueeE/dsh-container/actions/workflows/image.yml)
[![GHCR](https://img.shields.io/badge/ghcr.io-niyueee%2Fdsh--container-2088FF?logo=docker&logoColor=white)](https://github.com/NIyueeE/dsh-container/pkgs/container/dsh-container)
[![Upstream dsh](https://img.shields.io/github/v/tag/deepseek-ai/deepseek-harness?filter=dsh-v*&label=upstream%20dsh&sort=semver)](https://github.com/deepseek-ai/deepseek-harness)
[![License](https://img.shields.io/github/license/NIyueeE/dsh-container)](LICENSE)

[English](README.md) | 中文

</div>

## 快速开始

### Docker Compose(Linux)

```bash
docker compose -f examples/compose.yaml up -d
docker compose logs dsh | grep 'dsh web:'
# open http://127.0.0.1:3081/ in your local browser (the proxy redirects to dsh's launch token)
```

### Podman Quadlet(Linux,推荐)

```bash
sudo mkdir -p /etc/containers/systemd
sudo cp examples/dsh.container /etc/containers/systemd/
sudo systemctl daemon-reload
sudo systemctl enable --now dsh.service
```

两个示例都发布 `127.0.0.1:3081`,并把一个卷挂载到 `/home/dsh`——用户层(`~/.dsh`、缓存、自装工具)在镜像升级后保持不变,系统层随镜像更新。首次访问会重定向到 dsh 的 launch token,浏览器随后持有会话 cookie;没有单独的登录表单。

## 镜像内容

| 组件 | 说明 |
|---|---|
| 基础镜像 | `debian:13-slim`(已钉版本,可用 `BASE_IMAGE` 构建参数覆盖) |
| 工具链 | Node.js 22 LTS、pnpm、uv、Rust/cargo(含 rustfmt/clippy)、git + git-lfs、build-essential、Caddy、podman + crun、gh、yq——镜像持有的真实二进制,随镜像升级 |
| agent 常用工具 | ripgrep、fd、python3、zip、openssh-client、tmux、sqlite3、vim.tiny/nano、less、rsync、wget、tree、htop、tzdata、patch,外加一组诊断工具(dig/nc/socat/traceroute/iperf3/nft、file、ncdu、strace、zstd/lz4、bc、moreutils、pv、uuid-runtime)、xdg-user-dirs(UI 默认 workspace)与开发工具(just、shellcheck)——全部烘干进系统层,全新容器开箱即用、无需重新下载(运行期 `apt install` 会随容器重建丢失) |
| 嵌套容器 | 容器内( rootless )podman 已预配置 `XDG_RUNTIME_DIR`、subuid/subgid 与网络/sysctl 默认值;宿主运行时需允许非特权用户命名空间 + `/dev/fuse` + `/dev/net/tun`,且不得对容器的 `/proc` 加 masked/只读子挂载(`--security-opt unmask=ALL`、Quadlet `Unmask=ALL`、Docker `systempaths=unconfined`);嵌套容器内的资源限制(`--memory`/`--cpus`)不生效(cgroup v2 约束)——见 [docs/deployment.md](docs/deployment.md) § In-container podman |
| dsh | 从官方源码 tag 构建至 `/opt/deepseek-harness`(`DSH_TAG` 可钉版本,最低 0.2.1-alpha.3);运行期无自动更新 |
| 暴露方式 | Caddy 反向代理(`0.0.0.0:3081` → dsh 的 `127.0.0.1:3080`);保留浏览器 `Host`/`Origin`,首次访问重定向到 dsh 的登录 token,保留可选 basic auth |
| 守护 | `dsh web` 退出自动重启;`docker exec dsh dsh-restart` 手动重启 |
| 远程兼容 | 一个容器适配插件(`container/plugin/`,经 `dsh --patch` 挂载):把 dsh 的 launch token 写给代理登录重定向(浏览器自己持有会话 cookie)、无桌面环境下隐藏"打开配置文件"按钮(`describe` 报告无本地文档)、`/container-assets/*` 提供构建期抽出的图片 |
| 可观测性 | OCI labels、`HEALTHCHECK`(curl 3080 + 3081) |
| 运行用户 | uid 1000(`dsh`),免密 sudo;`/home/dsh` 为持久化用户层 |

## 容器适配插件

对上游 dsh(0.2.1-alpha.3 及更新版本)的全部容器侧适配收敛在**一个 Cordis 插件**里,随镜像装在
`/opt/dsh-container-plugin`,经 `dsh --patch` 挂载进 web profile:

- **launch token 登录重定向** —— 插件把 dsh 进程的 launch token 写到 `/tmp/dsh-caddy/launch-token`;Caddy 对没有会话 cookie 的浏览器 302 到 `/?token=...`,dsh 随后 Set-Cookie(`HttpOnly; SameSite=Strict`)。容器不再注入或改写会话,浏览器自己持有。
- **隐藏"打开配置文件"按钮** —— 上游该操作没有无桌面兜底,在容器里会 spawn `xdg-open` 扑空;插件让 `settings/describe` 报告 `hasDocument: false`,按钮按上游自身 UI 逻辑不再渲染。设置项持久化在挂载卷的 `~/.dsh` 下(上游 v0.1.7+ 按 profile 存于 `~/.dsh/profiles/<profile>/cordis.patch.yml`;旧版 `settings.yaml` 只导入一次)。
- **产物后处理** —— `pnpm run build:official` 之后跑三步:≥ 100 KiB 的内联图片抽成 `/container-assets/<内容哈希>`(由插件以 `immutable` 提供,只在真正打开对应界面时才取)、客户端 bundle 用 esbuild 压缩、刷新 `.dsh-build` 构建记录使其继续与交付产物一致。

插件是唯一的适配维护点。上游若新增 API 使其中一部分冗余,发布流水线会自动删除对应部分(体现在该次发布的 commit 列表中,见 [docs/upstream-contract.md](docs/upstream-contract.md) § 简化触发器)。

## 网络与安全

- **端口模型**——`dsh web` 监听 `127.0.0.1:3080`(上游拒绝 `--host 0.0.0.0`);对外端口是 `3081`,示例默认发布在宿主回环地址。
- **代理保留围栏**——Caddy 原样转发浏览器的 `Host`/`Origin`,dsh 的 `/api` 围栏真实生效。外部 authority 必须列在 `DSH_TRUSTED_HOST`(或从 `DSH_PUBLIC_URL` 派生);其它 Host 由 Caddy 直接 403,这是防 DNS rebinding 的关键。任何能访问 `3081` 的人都能登录:请启用 basic auth(`DSH_PROXY_USER`/`DSH_PROXY_PASSWORD`,成对设置,否则守护脚本 dsh-web 拒绝启动)并保持端口防火墙关闭。`/api/remote.mux` 的 WebSocket 不要求 basic auth(浏览器不保证给升级请求带 `Authorization`),由浏览器的 `SameSite=Strict` cookie 认证。
- **会话由浏览器持有**——首次无 cookie 访问会被 302 到 dsh 的 launch token;dsh Set-Cookie 后浏览器自己携带。容器不再注入 cookie。DeepSeek 账号登录仍要求浏览器 origin 是 loopback(SSH 隧道),公网域名不行——见 [docs/deployment.md](docs/deployment.md) § DeepSeek account sign-in。
- **流、体积与缓存**——SSE/WebSocket 无缓冲直通(已对 Caddy 2.6 验证),dsh 的 2 秒心跳可穿过该跳。客户端 bundle 在构建期做了后处理,无头浏览器实测冷启动整页约 **1.6 MiB(线上字节)** 而非约 5.8 MiB:57 模块合并包从 5.06 MiB 降到约 1.0 MiB gzip(≥ 100 KiB 的内联图片被抽出,只在打开对应界面时才取;bundle 只压空白与语法,不改标识符)。索引 `no-store`,内容哈希的 `/assets/*` 由代理标 `immutable`,重复访问因此很便宜。
- **遥测默认关闭** —— entrypoint 设置 `DSH_TELEMETRY_MODE=DISABLED`,OTel 反馈上报在你显式打开前不会发送任何内容。与之独立的是上游的 DeepSeek 会话日志贡献者,它**默认开启**,会把会话日志后缀附加到 DeepSeek API 请求上——发送内容与关闭方式见 [docs/security.md](docs/security.md)。
- **附加参数**——通过容器 command 透传 `dsh web` 参数,例如 `["--port", "8080"]`(仅改内部端口;对外端口仍为 `3081`)。

广域网访问请在前置代理上终结 TLS(文档含可用的 nginx 配置,含 WebSocket 头与超时设置)——详见 [docs/deployment.md](docs/deployment.md) 与 [docs/security.md](docs/security.md)。

## 环境变量

| 变量 | 默认值 | 说明 |
|---|---|---|
| `DSH_PROXY_USER` / `DSH_PROXY_PASSWORD` | *(空)* | 对外代理的 basic auth(任何非回环部署都建议启用);成对设置或都不设;`/api/remote.mux` 例外,由 dsh 会话 cookie 认证 |
| `DSH_PUBLIC_URL` | `http://127.0.0.1:3081/` | 浏览器实际访问的根 URL,用于 dsh/agent 上下文公告和登录 token URL;LAN/公网应设成真实外部地址。它不授予信任 |
| `DSH_TRUSTED_HOST` | *(空;从 `DSH_PUBLIC_URL` 派生)* | 逗号分隔的额外 authority(host 或 host:port),同时进入 dsh 围栏与 Caddy Host 允许列表 |
| `DSH_TELEMETRY_MODE` | `DISABLED` | OTel 反馈上报策略;`FEEDBACK_ONLY` 恢复上游默认(显式反馈时上传),`DISABLED` 让 OTel 路径留在本地。它**不**控制 DeepSeek 会话日志贡献者([security.md](docs/security.md)) |

其余全部使用内置默认值——dsh 数据在 `~/.dsh`,工作目录 `$HOME`,可写缓存在 `~/.cargo` / `~/.local/share`,镜像持有的工具在 `/usr/local/bin` 与 `/opt/rust`。整个 `/home/dsh` 是持久化边界:把它作为单一卷挂载;镜像升级替换工具链,从不动数据。细节见 [docs/build.md](docs/build.md) 与 [docs/deployment.md](docs/deployment.md)。

## 文档

| 文档 | 内容 |
|---|---|
| [docs/deployment.md](docs/deployment.md) | 部署与维护:Compose、Quadlet、远程访问、离线使用、FAQ |
| [docs/security.md](docs/security.md) | 安全说明:网络暴露取舍、凭据、可信工作负载 |
| [docs/build.md](docs/build.md) | 构建配置:构建参数、源码版本钉定、可复现构建 |
| [docs/releasing.md](docs/releasing.md) | 发布自动化:上游 tag 监视、契约检查、agent 修复、自动发布 |
| [docs/upstream-contract.md](docs/upstream-contract.md) | 本镜像依赖的上游行为,以及漂移的检测方式 |
| [docs/development.md](docs/development.md) | 目录结构与本地开发 |

## 许可证

[MIT](LICENSE)