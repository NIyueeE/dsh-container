# dsh 容器镜像

DeepSeek Harness(`dsh`)的容器化镜像,基于微软通用开发容器镜像
[`mcr.microsoft.com/devcontainers/universal`](https://mcr.microsoft.com/en-us/artifact/mcr/devcontainers/universal/about),
开箱即用,支持 **dsh 自动更新**。镜像发布在 GitHub Container Registry,
`compose.yaml` 与 Quadlet `.container` 示例均直接拉取镜像,不本地构建。

DSH 本体来自官方仓库 [deepseek-ai/deepseek-harness](https://github.com/deepseek-ai/deepseek-harness),
安装方式遵循官方 README:安装 Node.js 后通过 npm 安装 `@deepseek-ai/dsh`。

## 镜像内容

| 组件 | 说明 |
|---|---|
| 基础镜像 | `mcr.microsoft.com/devcontainers/universal:6-noble`(Ubuntu 24.04,体积大但工具链齐全) |
| 自带工具链 | Node.js 22/24(nvm)、Python、Go、Java、Docker CLI/Engine、git、build-essential 等 |
| 补装工具链 | Rust/cargo(rustup minimal profile)、uv(astral 官方安装脚本) |
| dsh | npm 全局安装 `@deepseek-ai/dsh`,与官方 README 的 `npx @deepseek-ai/dsh web` 同源 |
| 自动更新 | 容器启动时自动把 dsh 更新到 npm 最新版(可关闭);镜像本身支持 `Pull=newer` / `AutoUpdate=registry` |
| 运行时用户 | uid 1000(universal 6.x 为 `codespace`,旧版 2.x 为 `vscode`,自动兼容) |

## 快速开始

### Docker Compose(Linux)

```bash
mkdir -p workspace && sudo chown -R 1000:1000 workspace   # 工作区属主对齐容器用户
docker compose -f examples/compose.yaml up -d
# 打开 http://127.0.0.1:3080
```

### Podman Quadlet(Linux,推荐)

```bash
sudo mkdir -p /etc/containers/systemd
sudo cp examples/dsh.container /etc/containers/systemd/
# 按需修改 examples/dsh.container 中的工作区路径
sudo systemctl daemon-reload
sudo systemctl enable --now dsh.service
```

完整说明见 [docs/deployment.md](docs/deployment.md)。

## 为什么用 host 网络?

`dsh web` 出于安全考虑**拒绝绑定 `0.0.0.0`**(避免把远程代码执行能力暴露到网络上),
只监听 `127.0.0.1`。因此两个编排示例都使用 host 网络,服务直接出现在宿主机
`http://127.0.0.1:3080`,不需要也不支持端口映射。远程访问请走 SSH 隧道或宿主机上的
反向代理,详见部署文档。

## 环境变量

| 变量 | 默认 | 说明 |
|---|---|---|
| `DSH_HOME` | `/dsh` | dsh 数据目录(profiles / sessions / 插件),建议挂载持久化卷 |
| `DSH_AUTO_UPDATE` | `1` | 容器启动时自动更新 dsh 到 npm 最新版;离线或失败时沿用镜像内版本 |
| `DSH_UPDATE_ONLY` | `0` | 设为 `1` 时只执行 dsh 更新并退出(供 timer/cron 定时更新) |

`dsh web` 的附加参数可通过容器 `command` 透传,例如 `["--port", "8080"]`。

## 目录结构

```
Containerfile            # 镜像构建(基础镜像 + rustup/uv + dsh + 入口)
container/
  entrypoint.sh          # 容器入口: 自动更新 + 启动 dsh web
  dsh-update.sh          # dsh 更新脚本(幂等,可单独执行)
examples/
  compose.yaml           # Docker Compose 示例(拉取镜像)
  dsh.container          # systemd Quadlet 示例(拉取镜像)
docs/
  deployment.md          # 部署与维护指南
.github/workflows/
  image.yml              # 构建并发布到 GHCR(含冒烟测试)
```

## 镜像标签

| 标签 | 来源 | 说明 |
|---|---|---|
| `latest` | main 分支 | 滚动更新 |
| `<commit-sha>` | 每次 push | 精确可复现 |
| `v*`(如 `v1.2.0`) | 版本 tag | 语义化版本 |

## 开发

```sh
just build   # 本地构建 ghcr.io/niyueee/dsh-container:local
just debug   # 前台调试运行(host 网络)
```

## License

[MIT](LICENSE)
