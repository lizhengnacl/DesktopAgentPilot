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

健康检查：

```bash
curl http://localhost:3101/
```

固定返回：

```text
AgentPilot Server
```

## 构建

```bash
swift build
```

## 打包为 .app

```bash
./Scripts/package-app.sh
```

打包完成后，应用会生成在：

```text
.build/app/DesktopAgentPilot.app
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
