import CryptoKit
import Foundation
@preconcurrency import Network

struct HTTPRequest {
    var method: String
    var path: String
    var query: [String: String]
    var headers: [String: String]
    var body: Data
}

struct HTTPResponse {
    var status: Int
    var headers: [String: String]
    var body: Data
}

enum AgentPilotServiceState: String, Sendable {
    case stopped
    case starting
    case running
    case failed
}

struct AgentPilotServiceUpdate: Sendable {
    var state: AgentPilotServiceState
    var message: String
}

final class AgentPilotServer: @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private var listener: NWListener?
    private var state: AgentPilotServiceState = .stopped
    private var clients: [ObjectIdentifier: WebSocketClient] = [:]
    private let skillDiscovery = SkillDiscovery()
    private let cliManager: CLIManager
    private let store: AgentStore
    private let workspaceService: WorkspaceService
    private let port: UInt16
    var listenPort: UInt16 { port }
    var statusChanged: (@MainActor @Sendable (AgentPilotServiceUpdate) -> Void)?

    init(port: UInt16 = UInt16(ProcessInfo.processInfo.environment["PORT"] ?? "") ?? 3101) {
        let initialConfig = CLIConfig()
        let cli = CLIManager(config: initialConfig)
        self.cliManager = cli
        self.store = AgentStore(config: initialConfig)
        self.workspaceService = WorkspaceService { cli.getConfig().workDir }
        self.port = port
        cli.setEventHandler { [weak self] event in
            self?.broadcast(event)
        }
        store.recordWorkDir(initialConfig.workDir)
    }

    func start() throws {
        lock.lock()
        if listener != nil || state == .starting || state == .running {
            let currentState = state
            lock.unlock()
            notifyStatus(state: currentState, message: currentState == .starting ? "服务正在启动" : "服务已在运行")
            return
        }
        state = .starting
        lock.unlock()

        notifyStatus(state: .starting, message: "正在绑定本机端口 \(port)...")

        let nwPort = NWEndpoint.Port(rawValue: port)!
        let listener: NWListener
        do {
            listener = try NWListener(using: .tcp, on: nwPort)
        } catch {
            setStatus(state: .failed, message: "服务启动失败: \(error.localizedDescription)")
            throw error
        }

        listener.stateUpdateHandler = { [weak self, weak listener] state in
            guard let self, let listener, self.isCurrentListener(listener) else { return }
            switch state {
            case .ready:
                self.setStatus(state: .running, message: "服务已就绪，可接受 HTTP 与 WebSocket 连接")
            case .failed(let error):
                self.clearCurrentListener(listener)
                self.setStatus(state: .failed, message: "服务启动失败: \(error.localizedDescription)")
            case .cancelled:
                self.clearCurrentListener(listener)
                self.setStatus(state: .stopped, message: "服务已关闭")
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else {
                connection.cancel()
                return
            }
            HTTPConnection(connection: connection, server: self).start()
        }
        lock.lock()
        self.listener = listener
        lock.unlock()
        listener.start(queue: DispatchQueue(label: "desktop-agentpilot.server.listener"))
    }

    func stop() {
        lock.lock()
        let activeClients = Array(clients.values)
        clients.removeAll()
        let activeListener = listener
        listener = nil
        lock.unlock()
        activeClients.forEach { $0.close() }
        activeListener?.cancel()
        setStatus(state: .stopped, message: "服务已关闭")
    }

    private func isCurrentListener(_ candidate: NWListener) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let listener else { return false }
        return listener === candidate
    }

    private func clearCurrentListener(_ candidate: NWListener) {
        lock.lock()
        if listener === candidate {
            listener = nil
        }
        lock.unlock()
    }

    private func setStatus(state nextState: AgentPilotServiceState, message: String) {
        lock.lock()
        state = nextState
        lock.unlock()
        notifyStatus(state: nextState, message: message)
    }

    private func notifyStatus(state: AgentPilotServiceState, message: String) {
        guard let handler = statusChanged else { return }
        let update = AgentPilotServiceUpdate(state: state, message: message)
        Task { @MainActor in
            handler(update)
        }
    }

    func addClient(_ client: WebSocketClient) {
        lock.lock()
        clients[ObjectIdentifier(client)] = client
        lock.unlock()
    }

    func removeClient(_ client: WebSocketClient) {
        lock.lock()
        clients.removeValue(forKey: ObjectIdentifier(client))
        lock.unlock()
    }

    func broadcast(_ rawEvent: [String: Any]) {
        var event = rawEvent
        store.appendEvent(&event)
        let data = JSONSupport.data(event)

        lock.lock()
        let activeClients = Array(clients.values)
        lock.unlock()
        activeClients.forEach { $0.send(data) }
    }

    func handleHTTP(_ request: HTTPRequest) -> HTTPResponse {
        do {
            if request.method == "OPTIONS" {
                return HTTPResponse(status: 204, headers: corsHeaders(), body: Data())
            }

            if request.path == "/" || request.path == "/health" {
                return text(200, "AgentPilot Server")
            }

            guard request.path.hasPrefix("/api/") else {
                return json(404, ["error": "Not found"])
            }

            switch (request.method, request.path) {
            case ("GET", "/api/config"):
                return json(200, configPayload(type: nil))

            case ("GET", "/api/skills"):
                let config = cliManager.getConfig()
                return json(200, ["skills": skillDiscovery.discover(workDir: config.workDir)])

            case ("GET", "/api/workdirs"):
                let current = currentWorkDir()
                return json(200, [
                    "current": current,
                    "workdirs": store.recentWorkDirs(current: current),
                ])

            case ("GET", "/api/session"):
                return json(200, store.sessionData(
                    afterSeq: request.query["afterSeq"],
                    beforeSeq: request.query["beforeSeq"],
                    limit: request.query["limit"]
                ))

            case ("GET", "/api/history"):
                return json(200, ["tasks": store.historyList(workDir: currentWorkDir())])

            case ("DELETE", "/api/history"):
                store.clearHistory(workDir: currentWorkDir())
                broadcast(["type": "history_changed", "time": shortLocalTime()])
                return json(200, ["success": true])

            case ("POST", "/api/migrate-local-data"):
                let body = try JSONSupport.parseObject(request.body)
                store.importLocalData(
                    messages: body["messages"] as? [Any] ?? [],
                    historyTasks: body["historyTasks"] as? [Any] ?? [],
                    workDir: currentWorkDir()
                )
                return json(200, ["success": true])

            case ("GET", "/api/dir"):
                let includeFiles = request.query["includeFiles"] == "true"
                return json(200, try workspaceService.listSystemDir(request.query["dir"], includeFiles: includeFiles))

            case ("GET", "/api/workdir/tree"):
                return json(200, try workspaceService.listWorkspaceDir(request.query["path"] ?? ""))

            case ("GET", "/api/workdir/file"):
                return json(200, try workspaceService.readWorkspaceFile(request.query["path"] ?? ""))

            case ("GET", "/api/workdir/changes"):
                return json(200, try workspaceService.getWorkspaceChanges(request.query["path"]))

            case ("POST", "/api/workdir/track"):
                let body = try JSONSupport.parseObject(request.body)
                return json(200, try workspaceService.trackWorkspaceFile(body["path"]))

            case ("POST", "/api/workdir/stage"):
                let body = try JSONSupport.parseObject(request.body)
                return json(200, try workspaceService.stageWorkspacePath(body["path"]))

            case ("POST", "/api/workdir/unstage"):
                let body = try JSONSupport.parseObject(request.body)
                return json(200, try workspaceService.unstageWorkspacePath(body["path"]))

            case ("POST", "/api/workdir/commit-message"):
                return json(200, try generateWorkspaceCommitMessage())

            case ("POST", "/api/workdir/commit"):
                let body = try JSONSupport.parseObject(request.body)
                let result = try workspaceService.commitWorkspaceChanges(body["message"])
                broadcast(["type": "history_changed", "time": shortLocalTime()])
                return json(200, result)

            default:
                if request.path.hasPrefix("/api/history/") {
                    let id = String(request.path.dropFirst("/api/history/".count)).removingPercentEncoding ?? ""
                    if request.method == "GET" {
                        return json(200, ["task": store.historyTask(id: id, workDir: currentWorkDir()) as Any])
                    }
                    if request.method == "DELETE" {
                        store.deleteHistoryTask(id: id, workDir: currentWorkDir())
                        broadcast(["type": "history_changed", "time": shortLocalTime()])
                        return json(200, ["id": id])
                    }
                }
                return json(404, ["error": "Not found"])
            }
        } catch {
            return json(400, ["error": error.localizedDescription])
        }
    }

    func handleWebSocketMessage(_ client: WebSocketClient, text: String) {
        guard let data = text.data(using: .utf8),
              let msg = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = msg["type"] as? String else {
            client.send(jsonObject: ["type": "error", "content": "无效的消息格式", "time": shortLocalTime()])
            return
        }

        switch type {
        case "start_cli":
            store.archiveCurrentSession(status: "completed")
            cliManager.start(msg)
            store.recordWorkDir(currentWorkDir())
            _ = store.createSession(config: cliManager.getConfig())
            broadcast(["type": "session_reset", "sessionId": store.currentSessionId(), "config": cliManager.getConfig().json(), "time": shortLocalTime()])
            broadcast(["type": "history_changed", "time": shortLocalTime()])
            broadcast(["type": "workdirs_changed", "current": currentWorkDir(), "time": shortLocalTime()])

        case "send_message":
            let content = msg["content"] as? String ?? ""
            cliManager.sendInput(content)
            broadcast(["type": "user_message", "content": content, "time": shortLocalTime()])

        case "confirm_response":
            cliManager.confirmResponse((msg["approved"] as? Bool) ?? false)

        case "question_response":
            cliManager.questionResponse(msg["answer"] as? String ?? "", toolUseId: msg["toolUseId"] as? String)

        case "interrupt":
            cliManager.interrupt()

        case "restart_cli":
            store.archiveCurrentSession(status: cliManager.status == "running" ? "running" : "completed")
            _ = store.createSession(config: cliManager.getConfig())
            broadcast(["type": "session_reset", "sessionId": store.currentSessionId(), "config": cliManager.getConfig().json(), "time": shortLocalTime()])
            broadcast(["type": "history_changed", "time": shortLocalTime()])
            cliManager.restart()

        case "set_confirm_mode":
            let mode = msg["mode"] as? String ?? "key"
            cliManager.setConfirmMode(mode)
            broadcast(["type": "confirm_mode_changed", "mode": mode, "time": shortLocalTime()])

        case "get_config":
            client.send(jsonObject: configPayload(type: "config"))

        case "get_skills":
            client.send(jsonObject: [
                "type": "skills_data",
                "requestId": msg["requestId"] ?? "",
                "skills": skillDiscovery.discover(workDir: currentWorkDir()),
            ])

        case "get_session":
            var payload = store.sessionData(
                afterSeq: msg["afterSeq"],
                beforeSeq: msg["beforeSeq"],
                limit: msg["limit"]
            )
            payload["type"] = "session_data"
            payload["requestId"] = msg["requestId"] ?? ""
            client.send(jsonObject: payload)

        case "get_history":
            client.send(jsonObject: [
                "type": "history_data",
                "requestId": msg["requestId"] ?? "",
                "tasks": store.historyList(workDir: currentWorkDir()),
            ])

        case "get_history_task":
            let id = msg["id"] as? String ?? ""
            client.send(jsonObject: [
                "type": "history_task_data",
                "requestId": msg["requestId"] ?? "",
                "task": store.historyTask(id: id, workDir: currentWorkDir()) as Any,
            ])

        case "resume_history":
            resumeHistory(client, msg)

        case "edit_user_message":
            editUserMessage(client, msg)

        case "delete_history":
            let id = msg["id"] as? String ?? ""
            store.deleteHistoryTask(id: id, workDir: currentWorkDir())
            client.send(jsonObject: ["type": "history_deleted", "requestId": msg["requestId"] ?? "", "id": id])
            broadcast(["type": "history_changed", "time": shortLocalTime()])

        case "clear_history":
            store.clearHistory(workDir: currentWorkDir())
            client.send(jsonObject: ["type": "history_cleared", "requestId": msg["requestId"] ?? ""])
            broadcast(["type": "history_changed", "time": shortLocalTime()])

        case "migrate_local_data":
            store.importLocalData(messages: msg["messages"] as? [Any] ?? [], historyTasks: msg["historyTasks"] as? [Any] ?? [], workDir: currentWorkDir())
            client.send(jsonObject: ["type": "migration_done", "requestId": msg["requestId"] ?? "", "success": true])

        case "list_dir":
            do {
                var result = try workspaceService.listSystemDir(msg["dir"], includeFiles: (msg["includeFiles"] as? Bool) ?? false)
                result["type"] = "dir_list"
                result["requestId"] = msg["requestId"] ?? ""
                client.send(jsonObject: result)
            } catch {
                client.send(jsonObject: ["type": "dir_list", "requestId": msg["requestId"] ?? "", "dir": msg["dir"] ?? "", "error": error.localizedDescription])
            }

        case "list_workdir":
            sendWorkspaceRPC(client, requestId: msg["requestId"], type: "workdir_tree") {
                try workspaceService.listWorkspaceDir(msg["path"] ?? "")
            }

        case "read_workdir_file":
            sendWorkspaceRPC(client, requestId: msg["requestId"], type: "workdir_file") {
                try workspaceService.readWorkspaceFile(msg["path"] ?? "")
            }

        case "get_workdir_changes":
            sendWorkspaceRPC(client, requestId: msg["requestId"], type: "workdir_changes") {
                try workspaceService.getWorkspaceChanges(msg["path"])
            }

        case "track_workdir_file":
            sendWorkspaceRPC(client, requestId: msg["requestId"], type: "workdir_file_tracked") {
                try workspaceService.trackWorkspaceFile(msg["path"])
            }

        case "generate_workdir_commit_message":
            sendWorkspaceRPC(client, requestId: msg["requestId"], type: "workdir_commit_message") {
                try generateWorkspaceCommitMessage()
            }

        case "commit_workdir_changes":
            sendWorkspaceRPC(client, requestId: msg["requestId"], type: "workdir_committed") {
                let result = try workspaceService.commitWorkspaceChanges(msg["message"])
                broadcast(["type": "history_changed", "time": shortLocalTime()])
                return result
            }

        default:
            client.send(jsonObject: ["type": "error", "content": "未知消息类型: \(type)", "time": shortLocalTime()])
        }
    }

    func connectedPayload() -> [String: Any] {
        [
            "type": "connected",
            "config": cliManager.getConfig().json(),
            "status": cliManager.status,
            "sessionId": store.currentSessionId(),
        ]
    }

    private func sendWorkspaceRPC(_ client: WebSocketClient, requestId: Any?, type: String, operation: () throws -> [String: Any]) {
        do {
            var result = try operation()
            result["type"] = type
            result["requestId"] = requestId ?? ""
            client.send(jsonObject: result)
        } catch {
            client.send(jsonObject: ["type": type, "requestId": requestId ?? "", "error": error.localizedDescription])
        }
    }

    private func resumeHistory(_ client: WebSocketClient, _ msg: [String: Any]) {
        if ["running", "confirm", "question"].contains(cliManager.status) {
            client.send(jsonObject: [
                "type": "history_resumed",
                "requestId": msg["requestId"] ?? "",
                "success": false,
                "error": "当前会话正在响应中，请等待完成后再继续该会话",
            ])
            return
        }

        let id = msg["id"] as? String ?? ""
        guard let restored = store.resumeHistoryTask(id: id, workDir: currentWorkDir(), config: cliManager.getConfig()),
              let cliSessionId = restored.cliSessionId else {
            client.send(jsonObject: [
                "type": "history_resumed",
                "requestId": msg["requestId"] ?? "",
                "success": false,
                "error": "该会话记录缺少可恢复的 CLI 会话 ID，无法继续追问",
            ])
            return
        }

        var config = cliManager.getConfig()
        config.cliSessionId = cliSessionId
        cliManager.restoreConfig(config)
        cliManager.restoreSessionId(cliSessionId)
        store.recordWorkDir(currentWorkDir())

        let messages = restored.messages.compactMap { $0.clientMessage() }
        broadcast([
            "type": "session_restored",
            "sessionId": store.currentSessionId(),
            "config": cliManager.getConfig().json(),
            "status": cliManager.status,
            "messages": messages,
            "lastSeq": restored.lastSeq,
            "time": shortLocalTime(),
        ])
        broadcast(["type": "history_changed", "time": shortLocalTime()])
        broadcast(["type": "workdirs_changed", "current": currentWorkDir(), "time": shortLocalTime()])

        let followUp = (msg["content"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !followUp.isEmpty {
            cliManager.sendInput(followUp)
            broadcast(["type": "user_message", "content": followUp, "time": shortLocalTime()])
        }

        client.send(jsonObject: [
            "type": "history_resumed",
            "requestId": msg["requestId"] ?? "",
            "success": true,
            "sessionId": store.currentSessionId(),
            "config": cliManager.getConfig().json(),
            "messages": messages,
            "lastSeq": restored.lastSeq,
            "sent": !followUp.isEmpty,
        ])
    }

    private func editUserMessage(_ client: WebSocketClient, _ msg: [String: Any]) {
        if ["running", "confirm", "question"].contains(cliManager.status) {
            client.send(jsonObject: ["type": "user_message_edited", "requestId": msg["requestId"] ?? "", "success": false, "error": "当前会话正在响应中，请等待完成后再编辑消息"])
            return
        }

        let messageId = msg["messageId"] as? String ?? ""
        let content = msg["content"] as? String ?? ""
        guard let branch = store.messageBeforeBranch(id: messageId),
              branch.target.type == "user_message" || branch.target.type == "user",
              !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            client.send(jsonObject: ["type": "user_message_edited", "requestId": msg["requestId"] ?? "", "success": false, "error": "未找到可编辑的用户消息"])
            return
        }

        var config = cliManager.getConfig()
        config.cliSessionId = nil
        cliManager.restoreConfig(config)
        cliManager.clearSessionId()
        let prefix = store.branchBefore(message: branch.target, config: config)
        let messages = prefix.compactMap { $0.clientMessage() }
        broadcast([
            "type": "session_restored",
            "sessionId": store.currentSessionId(),
            "config": cliManager.getConfig().json(),
            "status": cliManager.status,
            "messages": messages,
            "lastSeq": prefix.map(\.seq).max() ?? 0,
            "time": shortLocalTime(),
        ])
        broadcast(["type": "history_changed", "time": shortLocalTime()])

        cliManager.sendInput(buildEditPrompt(prefix: prefix, editedContent: content))
        broadcast(["type": "user_message", "content": content, "time": shortLocalTime()])
        client.send(jsonObject: ["type": "user_message_edited", "requestId": msg["requestId"] ?? "", "success": true, "sessionId": store.currentSessionId()])
    }

    private func buildEditPrompt(prefix: [SessionMessage], editedContent: String) -> String {
        let entries = prefix.compactMap { message -> String? in
            let content = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty else { return nil }
            if message.type == "user_message" || message.type == "user" { return "用户: \(content)" }
            if message.type == "ai_message" || message.type == "ai" { return "助手: \(content)" }
            if message.type == "tool_call" || message.type == "tool" { return "工具调用: \(content)" }
            return nil
        }.joined(separator: "\n\n")

        guard !entries.isEmpty else { return editedContent }
        return [
            "你正在一个新会话中接续一段用户已编辑的对话。",
            "下面是编辑点之前保留的对话记录，仅作为上下文；不要复述这段记录，直接回应最后的用户消息。",
            "",
            "<conversation_history>",
            entries,
            "</conversation_history>",
            "",
            "<edited_user_message>",
            editedContent,
            "</edited_user_message>",
        ].joined(separator: "\n")
    }

    private func generateWorkspaceCommitMessage() throws -> [String: Any] {
        let prompt = try workspaceService.buildCommitMessagePrompt()
        let output = try cliManager.runOneShot(prompt, timeout: 120)
        let message = workspaceService.normalizeAICommitMessage(output)
        guard !message.isEmpty else { throw WorkspaceError.message("AI 未生成有效提交信息") }
        return ["workDir": currentWorkDir(), "message": message]
    }

    private func configPayload(type: String?) -> [String: Any] {
        var payload: [String: Any] = [
            "config": cliManager.getConfig().json(),
            "status": cliManager.status,
            "sessionId": store.currentSessionId(),
            "time": shortLocalTime(),
        ]
        if let type { payload["type"] = type }
        return payload
    }

    private func currentWorkDir() -> String {
        cliManager.getConfig().workDir
    }

    private func corsHeaders() -> [String: String] {
        [
            "Access-Control-Allow-Origin": "*",
            "Access-Control-Allow-Methods": "GET,POST,DELETE,OPTIONS",
            "Access-Control-Allow-Headers": "Content-Type",
        ]
    }

    private func json(_ status: Int, _ object: [String: Any]) -> HTTPResponse {
        HTTPResponse(
            status: status,
            headers: corsHeaders().merging(["Content-Type": "application/json; charset=utf-8"]) { _, new in new },
            body: JSONSupport.data(object)
        )
    }

    private func text(_ status: Int, _ body: String) -> HTTPResponse {
        HTTPResponse(
            status: status,
            headers: corsHeaders().merging(["Content-Type": "text/plain; charset=utf-8"]) { _, new in new },
            body: Data(body.utf8)
        )
    }
}

final class HTTPConnection: @unchecked Sendable {
    private let connection: NWConnection
    private let server: AgentPilotServer
    private var buffer = Data()

    init(connection: NWConnection, server: AgentPilotServer) {
        self.connection = connection
        self.server = server
    }

    func start() {
        connection.start(queue: DispatchQueue(label: "desktop-agentpilot.http.connection"))
        receive()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
            if let data, !data.isEmpty {
                self.buffer.append(data)
                if self.tryHandleRequest() { return }
            }
            if error != nil || isComplete {
                self.connection.cancel()
                return
            }
            self.receive()
        }
    }

    private func tryHandleRequest() -> Bool {
        let delimiter = Data("\r\n\r\n".utf8)
        guard let headerRange = buffer.firstRange(of: delimiter) else { return false }
        let headerData = buffer[..<headerRange.lowerBound]
        guard let headerText = String(data: headerData, encoding: .utf8) else {
            send(HTTPResponse(status: 400, headers: ["Content-Type": "text/plain"], body: Data("Bad request".utf8)))
            return true
        }
        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            send(HTTPResponse(status: 400, headers: ["Content-Type": "text/plain"], body: Data("Bad request".utf8)))
            return true
        }
        let requestParts = requestLine.split(separator: " ", maxSplits: 2).map(String.init)
        guard requestParts.count >= 2 else {
            send(HTTPResponse(status: 400, headers: ["Content-Type": "text/plain"], body: Data("Bad request".utf8)))
            return true
        }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
            headers[key] = value
        }

        let bodyStart = headerRange.upperBound
        let contentLength = Int(headers["content-length"] ?? "0") ?? 0
        guard buffer.count >= bodyStart + contentLength else { return false }
        let body = buffer.subdata(in: bodyStart..<(bodyStart + contentLength))
        let leftover = buffer.count > bodyStart + contentLength ? buffer.subdata(in: (bodyStart + contentLength)..<buffer.count) : Data()

        if headers["upgrade"]?.lowercased() == "websocket" {
            upgradeToWebSocket(headers: headers, leftover: leftover)
            return true
        }

        let request = makeRequest(method: requestParts[0], target: requestParts[1], headers: headers, body: body)
        send(server.handleHTTP(request))
        return true
    }

    private func makeRequest(method: String, target: String, headers: [String: String], body: Data) -> HTTPRequest {
        let components = URLComponents(string: "http://\(LocalNetworkAddress.currentIPv4())\(target)")
        var query: [String: String] = [:]
        for item in components?.queryItems ?? [] {
            query[item.name] = item.value ?? ""
        }
        return HTTPRequest(
            method: method,
            path: components?.path ?? target,
            query: query,
            headers: headers,
            body: body
        )
    }

    private func send(_ response: HTTPResponse) {
        var headers = response.headers
        headers["Content-Length"] = "\(response.body.count)"
        headers["Connection"] = "close"
        let reason = HTTPConnection.reasonPhrase(response.status)
        var data = Data("HTTP/1.1 \(response.status) \(reason)\r\n".utf8)
        for (key, value) in headers {
            data.append(Data("\(key): \(value)\r\n".utf8))
        }
        data.append(Data("\r\n".utf8))
        data.append(response.body)
        connection.send(content: data, completion: .contentProcessed { [weak self] _ in
            self?.connection.cancel()
        })
    }

    private func upgradeToWebSocket(headers: [String: String], leftover: Data) {
        guard let key = headers["sec-websocket-key"] else {
            send(HTTPResponse(status: 400, headers: ["Content-Type": "text/plain"], body: Data("Missing Sec-WebSocket-Key".utf8)))
            return
        }
        let accept = WebSocketClient.acceptKey(for: key)
        let response = [
            "HTTP/1.1 101 Switching Protocols",
            "Upgrade: websocket",
            "Connection: Upgrade",
            "Sec-WebSocket-Accept: \(accept)",
            "\r\n",
        ].joined(separator: "\r\n")
        connection.send(content: Data(response.utf8), completion: .contentProcessed { error in
            guard error == nil else {
                self.connection.cancel()
                return
            }
            let client = WebSocketClient(connection: self.connection, server: self.server)
            client.start(initialData: leftover)
        })
    }

    private static func reasonPhrase(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 204: return "No Content"
        case 400: return "Bad Request"
        case 404: return "Not Found"
        case 500: return "Internal Server Error"
        default: return "OK"
        }
    }
}

final class WebSocketClient: @unchecked Sendable {
    private let connection: NWConnection
    private weak var server: AgentPilotServer?
    private let sendQueue = DispatchQueue(label: "desktop-agentpilot.websocket.send")
    private var buffer = Data()
    private var isClosed = false

    init(connection: NWConnection, server: AgentPilotServer) {
        self.connection = connection
        self.server = server
    }

    func start(initialData: Data) {
        server?.addClient(self)
        send(jsonObject: server?.connectedPayload() ?? [:])
        if !initialData.isEmpty {
            buffer.append(initialData)
            parseFrames()
        }
        receive()
    }

    func send(jsonObject: [String: Any]) {
        send(JSONSupport.data(jsonObject))
    }

    func send(_ payload: Data) {
        guard !isClosed else { return }
        let frame = WebSocketClient.frame(opcode: 0x1, payload: payload)
        sendQueue.async { [weak self] in
            self?.connection.send(content: frame, completion: .contentProcessed { _ in })
        }
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        connection.send(content: WebSocketClient.frame(opcode: 0x8, payload: Data()), completion: .contentProcessed { [weak self] _ in
            self?.connection.cancel()
        })
        server?.removeClient(self)
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self, !self.isClosed else { return }
            if let data, !data.isEmpty {
                self.buffer.append(data)
                self.parseFrames()
            }
            if error != nil || isComplete {
                self.close()
                return
            }
            self.receive()
        }
    }

    private func parseFrames() {
        while true {
            guard buffer.count >= 2 else { return }
            let bytes = [UInt8](buffer)
            let first = bytes[0]
            let second = bytes[1]
            let opcode = first & 0x0F
            let masked = (second & 0x80) != 0
            var length = Int(second & 0x7F)
            var offset = 2

            if length == 126 {
                guard buffer.count >= offset + 2 else { return }
                length = Int(bytes[offset]) << 8 | Int(bytes[offset + 1])
                offset += 2
            } else if length == 127 {
                guard buffer.count >= offset + 8 else { return }
                var value: UInt64 = 0
                for index in 0..<8 {
                    value = (value << 8) | UInt64(bytes[offset + index])
                }
                guard value <= UInt64(Int.max) else {
                    close()
                    return
                }
                length = Int(value)
                offset += 8
            }

            var mask: [UInt8] = []
            if masked {
                guard buffer.count >= offset + 4 else { return }
                mask = Array(bytes[offset..<(offset + 4)])
                offset += 4
            }

            guard buffer.count >= offset + length else { return }
            var payload = Array(bytes[offset..<(offset + length)])
            if masked {
                for index in 0..<payload.count {
                    payload[index] ^= mask[index % 4]
                }
            }
            buffer.removeSubrange(0..<(offset + length))

            switch opcode {
            case 0x1:
                if let text = String(data: Data(payload), encoding: .utf8) {
                    server?.handleWebSocketMessage(self, text: text)
                }
            case 0x8:
                close()
                return
            case 0x9:
                connection.send(content: WebSocketClient.frame(opcode: 0xA, payload: Data(payload)), completion: .contentProcessed { _ in })
            default:
                break
            }
        }
    }

    static func acceptKey(for key: String) -> String {
        let magic = key.trimmingCharacters(in: .whitespacesAndNewlines) + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
        let digest = Insecure.SHA1.hash(data: Data(magic.utf8))
        return Data(digest).base64EncodedString()
    }

    static func frame(opcode: UInt8, payload: Data) -> Data {
        var frame = Data()
        frame.append(0x80 | opcode)
        if payload.count < 126 {
            frame.append(UInt8(payload.count))
        } else if payload.count <= UInt16.max {
            frame.append(126)
            frame.append(UInt8((payload.count >> 8) & 0xff))
            frame.append(UInt8(payload.count & 0xff))
        } else {
            frame.append(127)
            let length = UInt64(payload.count)
            for shift in stride(from: 56, through: 0, by: -8) {
                frame.append(UInt8((length >> UInt64(shift)) & 0xff))
            }
        }
        frame.append(payload)
        return frame
    }
}
