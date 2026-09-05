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
# 在本地浏览器打开 http://127.0.0.1:3081/(代理自动完成登录)
```

### Podman Quadlet(Linux,推荐)

```bash
sudo mkdir -p /etc/containers/systemd
sudo cp examples/dsh.container /etc/containers/systemd/
sudo systemctl daemon-reload
sudo systemctl enable --now dsh.service
```

两个示例都发布 `127.0.0.1:3081`,并把一个卷挂载到 `/home/dsh`——用户层(`~/.dsh`、缓存、自装工具)在镜像升级后保持不变,系统层随镜像更新。没有登录步骤:代理会自动完成 dsh 会话引导。

## 镜像内容

| 组件 | 说明 |
|---|---|
| 基础镜像 | `debian:13-slim`(已钉版本,可用 `BASE_IMAGE` 构建参数覆盖) |
| 工具链 | Node.js 22 LTS、pnpm、uv、Rust/cargo、git、build-essential、Caddy、podman、gh——镜像持有的真实二进制,随镜像升级 |
| dsh | 从官方源码 tag 构建至 `/opt/deepseek-harness`(`DSH_TAG` 可钉版本);运行期无自动更新 |
| 暴露方式 | Caddy 反向代理(`0.0.0.0:3081` → dsh 的 `127.0.0.1:3080`),可选 basic auth |
| 守护 | `dsh web` 退出自动重启;`docker exec dsh dsh-restart` 手动重启 |
| 远程兼容 | 幂等客户端补丁:设置/凭据页可经代理使用;`crypto.randomUUID` polyfill 支持纯 HTTP 内网 |
| 可观测性 | OCI labels、`HEALTHCHECK`(curl 3080 + 3081) |
| 运行用户 | uid 1000(`dsh`),免密 sudo;`/home/dsh` 为持久化用户层 |

## 网络与安全

- **端口模型**——`dsh web` 监听 `127.0.0.1:3080`(上游拒绝 `--host 0.0.0.0`);对外端口是 `3081`,示例默认发布在宿主回环地址。
- **代理即安全边界**——Caddy 把 `Host`/`Origin` 改写为回环,远程浏览器因此通过 dsh 的 `/api` 信任围栏,包括原本仅限回环的设置/凭据接口。任何能访问 `3081` 的人都获得完全控制:请启用 basic auth(`DSH_PROXY_USER`/`DSH_PROXY_PASSWORD`,成对设置,否则 entrypoint 拒绝启动)并保持端口防火墙关闭。
- **会话自动引导**——supervisor 在启动时兑换 dsh 的一次性登录 token,并把会话 cookie 注入每个代理请求;浏览器不会接触 token。
- **流与压缩**——SSE/WebSocket 无缓冲直通(已对 Caddy 2.6 验证);UI 资源 gzip 压缩(约 1.3 MB → 360 KB)。
- **客户端补丁**——每次 `dsh web` 启动前应用;若上游改变 bundle 字符串则告警跳过,不阻塞启动。
- **附加参数**——通过容器 command 透传 `dsh web` 参数,例如 `["--port", "8080"]`(仅改内部端口;对外端口仍为 `3081`)。

广域网访问请在前置代理上终结 TLS(文档含可用的 nginx 配置,含 WebSocket 头与超时设置)——详见 [docs/deployment.md](docs/deployment.md) 与 [docs/security.md](docs/security.md)。

## 环境变量

| 变量 | 默认值 | 说明 |
|---|---|---|
| `DSH_PROXY_USER` / `DSH_PROXY_PASSWORD` | *(空)* | 对外代理的 basic auth(任何非回环部署都建议启用);成对设置或都不设 |

其余全部使用内置默认值——dsh 数据在 `~/.dsh`,工作目录 `$HOME`,可写缓存在 `~/.cargo` / `~/.local/share`,镜像持有的工具在 `/usr/local/bin` 与 `/opt/rust`。整个 `/home/dsh` 是持久化边界:把它作为单一卷挂载;镜像升级替换工具链,从不动数据。细节见 [docs/build.md](docs/build.md) 与 [docs/deployment.md](docs/deployment.md)。

## 文档

| 文档 | 内容 |
|---|---|
| [docs/deployment.md](docs/deployment.md) | 部署与维护:Compose、Quadlet、远程访问、离线使用、FAQ |
| [docs/security.md](docs/security.md) | 安全说明:网络暴露取舍、凭据、可信工作负载 |
| [docs/build.md](docs/build.md) | 构建配置:构建参数、源码版本钉定、可复现构建 |
| [docs/releasing.md](docs/releasing.md) | 发布自动化:上游 tag 监视、契约检查、agent 修复、自动发布 |
| [docs/upstream-contract.md](docs/upstream-contract.md) | 本镜像依赖的上游行为,以及漂移的检测方式 |
| [docs/design.md](docs/design.md) | 设计参考与相关项目 |
| [docs/development.md](docs/development.md) | 目录结构与本地开发 |

## 许可证

[MIT](LICENSE)