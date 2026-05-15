# DesktopAgentPilot

原生 macOS AgentPilot 桌面服务，使用 Swift Package Manager、AppKit、Network.framework 构建，无第三方依赖。

## 运行

默认监听 `3101`，提供 HTTP JSON API 和 WebSocket JSON 协议：

```bash
swift run DesktopAgentPilot
```

如端口被占用，可临时指定：

```bash
PORT=3999 swift run DesktopAgentPilot
```

桌面应用启动失败时，也可点击「关闭占用端口」来终止正在监听当前端口的进程，并自动重试启动。

启动后的默认工作目录为 `~`；通过会话配置切换过的工作目录会记录到本机偏好设置，重启后仍可从 `/api/workdirs` 获取。

健康检查：

```bash
curl http://<本机IP>:3101/
```

固定返回：

```text
AgentPilot Server
```

## 构建与安装

本地开发构建：

```bash
swift build
```

正式包构建会使用 release 配置，并生成 macOS `.app`：

```bash
./Scripts/package-app.sh
```

打包完成后，应用会生成在：

```text
.build/app/DesktopAgentPilot.app
```

安装到本机应用目录：

```bash
ditto .build/app/DesktopAgentPilot.app /Applications/DesktopAgentPilot.app
```

安装完成后，可从 Finder 的「应用程序」中启动 `DesktopAgentPilot`，或使用：

```bash
open /Applications/DesktopAgentPilot.app
```

## 已实现接口

- `GET /api/config`
- `GET /api/skills`
- `GET /api/workdirs`
- `GET /api/session`
- `GET /api/history`
- `GET /api/history/:id`
- `DELETE /api/history/:id`
- `DELETE /api/history`
- `POST /api/migrate-local-data`
- `GET /api/dir`
- `GET /api/workdir/tree`
- `GET /api/workdir/file`
- `GET /api/workdir/changes`
- `POST /api/workdir/track`
- `POST /api/workdir/stage`
- `POST /api/workdir/unstage`
- `POST /api/workdir/commit-message`
- `POST /api/workdir/commit`
- WebSocket 连接事件、会话控制、历史、目录、工作区文件/Git 旧 RPC。

CLI 会话按 `print` 模式桥接 Codex/Claude；工作区文件和 Git 操作会限制在当前 `workDir` 内。
