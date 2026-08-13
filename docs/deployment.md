# 部署与维护指南

本文档面向把 dsh 容器跑在自有主机上的场景(Linux, Docker 或 Podman)。

## 1. 前置条件

- Linux 主机(Docker Engine ≥ 24 或 Podman ≥ 4.4)
- 能访问 `ghcr.io` 与 `registry.npmjs.org`(容器启动时的 dsh 自动更新需要 npm registry;
  离线环境见下文「离线使用」)
- 端口 `3080` 未被占用

## 2. Docker Compose 部署

```bash
# 工作区目录: 容器内用户是 uid 1000, 宿主目录属主需对齐
mkdir -p workspace
sudo chown -R 1000:1000 workspace

docker compose -f examples/compose.yaml up -d
docker compose -f examples/compose.yaml logs -f
```

打开 `http://127.0.0.1:3080`。首次使用按 Web UI 引导配置模型(API Key)并选择工作区。

- `compose.yaml` 使用 `network_mode: host`,因此**不要**添加 `ports:` 映射
  (dsh 只监听 127.0.0.1,端口映射无效且会被忽略)。
- 数据持久化: `dsh-home` 命名卷保存 `$DSH_HOME`(profiles / sessions / 插件);
  `./workspace` 绑定到 `/workspace` 作为任务工作区。
- SELinux 主机(Fedora 等)保留卷定义中的 `:Z`。

## 3. Podman Quadlet 部署(推荐)

```bash
sudo mkdir -p /etc/containers/systemd
sudo cp examples/dsh.container /etc/containers/systemd/
# 按需修改 /home/you/workspace 为你的工作区路径
sudo systemctl daemon-reload
sudo systemctl enable --now dsh.service

systemctl status dsh.service
journalctl -u dsh.service -f
```

- `dsh.container` 同样使用 `Network=host`,访问 `http://127.0.0.1:3080`。
- 更新工作区路径后重新 `daemon-reload` + `restart`。
- 用户级部署(rootless podman)可把文件放到 `~/.config/containers/systemd/`,
  并把 `[Install]` 的 `WantedBy` 改为 `default.target`。

## 4. 自动更新机制

两层更新,互不冲突:

1. **dsh 自身(容器内)** —— 容器启动时 `entrypoint.sh` 调用 `dsh-update`:
   - 对比 `dsh --version` 与 `npm view @deepseek-ai/dsh version`;
   - 不一致时 `npm install -g` 更新(镜像内 npm 全局目录已授权给 uid 1000,无需 root);
   - 离线或失败时打印告警并沿用镜像内版本继续启动,不影响可用性。
   - 手动更新:`docker exec dsh dsh-update` / `systemctl restart dsh`。
   - 定时更新(可选): 把 `DSH_UPDATE_ONLY=1` 的容器交给 systemd timer 或 cron,
     例如每小时执行一次 `docker run --rm -e DSH_UPDATE_ONLY=1 ... dsh-container`。

2. **镜像本身(编排层)** ——
   - Quadlet 已配置 `Pull=newer`(重启时若远端有更新则拉取)与
     `AutoUpdate=registry`;再配合 `systemctl enable --now podman-auto-update.timer`
     即可定时拉取新镜像并重启容器。
   - Compose 可手动 `docker compose pull && docker compose up -d` 完成同样效果。

## 5. 安全注意事项

dsh 的 agent 能在容器内执行任意命令(远程代码执行能力是它的本职工作),请按以下基线使用:

- **不要往容器里挂载宿主密钥**: 避免绑定挂载 `~/.ssh`、`~/.aws`、`~/.config/gh`、
  云厂商凭据等(参考 [Claude Code 官方容器安全警告](https://code.claude.com/docs/en/devcontainer))。
  Agent 可以读取容器内一切可访问内容,包括挂载进来的凭据。
- **DSH_HOME 里存有 API Key**: `dsh-home` 卷包含模型 API 凭据与 session 数据,
  注意卷的访问权限与备份;不要把该卷共享给不受信任的容器。
- **只跑可信仓库的任务**: 即使有审批机制,也不要让 agent 处理不受信任的代码仓库。
- **远程访问只走 SSH 隧道**: dsh 只监听 127.0.0.1 是安全设计(见第 6 节),
  不要在宿主网络上直接暴露。

## 6. 远程访问(仅限本机回环之外的场景)

dsh 只监听 127.0.0.1 是安全设计(Web UI 有远程代码执行能力,绑定到网络会把
RCE 暴露给局域网)。远程使用推荐 **SSH 隧道**,不要改绑定地址:

```bash
ssh -L 3080:127.0.0.1:3080 user@your-host
# 本地浏览器打开 http://127.0.0.1:3080
```

如确需在宿主网络上暴露,请在宿主机配置带认证的反向代理(如 Caddy + basic auth),
并考虑 dsh 的 `--trusted-host` 选项。

## 7. 离线使用

- 构建镜像时把 `DSH_AUTO_UPDATE` 相关行为固化: 运行时设 `DSH_AUTO_UPDATE=0`
  (compose 里 `DSH_AUTO_UPDATE: "0"`,quadlet 里 `Environment=DSH_AUTO_UPDATE=0`)。
- dsh 版本由镜像构建时的 `--build-arg DSH_VERSION=x.y.z` 固定,更新走镜像发布流程。

## 7. 常见问题

**容器内写工作区报权限错误**
工作区宿主目录属主需为 uid 1000:`sudo chown -R 1000:1000 workspace`。

**端口 3080 被占用**
`dsh web` 支持 `--port`,compose 加 `command: ["--port", "8080"]`,
quadlet 加 `Exec=--port 8080`,然后访问新端口。

**启动日志出现 `npm registry unreachable`**
容器无法访问 npm registry,已自动沿用镜像内 dsh 版本;恢复网络后重启即可。

**Podman rootless + 绑定目录**
确认目录属主为你的 uid,且路径可被容器读取;SELinux 保留 `:Z` 标签。

## 8. 可复现构建与版本固定

镜像内所有可变组件都支持 `--build-arg` 固定(CI 只传 git 信息,其余用默认值):

| 构建参数 | 默认 | 说明 |
|---|---|---|
| `BASE_IMAGE` | `universal:latest` | 基础镜像(当前与 `6.1.1-noble` 同 digest;可固定精确 tag) |
| `DSH_VERSION` | `latest` | dsh 版本;固定后运行时建议同时 `DSH_AUTO_UPDATE=0` |
| `RUST_TOOLCHAIN` | `stable` | rust 工具链(如 `1.88.0`) |
| `UV_VERSION` | `0.12.3` | uv 版本(从官方镜像 COPY,不跑安装脚本) |
| `BUILD_GIT_SHA` / `BUILD_GIT_REF` | `unknown` | 写入 OCI labels(`org.opencontainers.image.*`) |

例(与 Claude Code 的 `DISABLE_AUTOUPDATER=1` 思路一致: 固定版本 + 关掉运行时自动更新):

```bash
podman build --build-arg DSH_VERSION=0.1.0-rc.6 \
             --build-arg RUST_TOOLCHAIN=1.88.0 \
             --build-arg UV_VERSION=0.12.3 \
             -t dsh-container .
# 运行时: DSH_AUTO_UPDATE=0
```

## 9. 镜像更新发布

推送 `main` 分支或 `v*` tag 到 GitHub 即触发
[`.github/workflows/image.yml`](../.github/workflows/image.yml):

- main → `latest` + `<sha>`;tag → `v*` + `<sha>`;
- 每个构建都跑冒烟测试(Web UI 可访问、dsh/工具链版本、更新脚本幂等);
- PR 只构建 + 冒烟,不推送。
