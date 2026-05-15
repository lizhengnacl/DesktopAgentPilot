import Foundation

typealias CLIEventHandler = ([String: Any]) -> Void

final class CLIOutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var stdoutBuffer = ""
    private var stderrBuffer = ""
    private var structuredError = false

    func appendStdout(_ text: String) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        stdoutBuffer += text
        let parts = stdoutBuffer.components(separatedBy: "\n")
        stdoutBuffer = parts.last ?? ""
        return Array(parts.dropLast())
    }

    func appendStderr(_ text: String) {
        lock.lock()
        stderrBuffer += text
        lock.unlock()
    }

    func markStructuredError() {
        lock.lock()
        structuredError = true
        lock.unlock()
    }

    func snapshot() -> (remaining: String, stderr: String, hasStructuredError: Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (
            stdoutBuffer.trimmingCharacters(in: .whitespacesAndNewlines),
            stderrBuffer.trimmingCharacters(in: .whitespacesAndNewlines),
            structuredError
        )
    }
}

private struct CLIPermissionDenial {
    var toolName: String
    var category: String
    var toolUseId: String?
    var input: [String: Any]
    var description: String
}

final class CLIManager: @unchecked Sendable {
    private static let askUserQuestionTool = "AskUserQuestion"
    private static let fileTools: Set<String> = ["Write", "Edit", "MultiEdit", "writeFile", "editFile", "readFile", "Read"]
    private static let commandTools: Set<String> = ["Bash", "bash", "Shell", "shell", "Exec", "exec"]
    private static let confirmPatterns = [
        #"\?\s*\[[yY]/[nN]\]"#,
        #"(?i)\(yes/no\)"#,
        #"(?i)\(y/n\)"#,
        #"(?i)allow.*\?"#,
        #"(?i)proceed.*\?"#,
        #"(?i)confirm.*\?"#,
        #"(?i)approve.*\?"#,
        #"\[Y/n\]"#,
    ]

    private let queue = DispatchQueue(label: "desktop-agentpilot.cli")
    private let lock = NSRecursiveLock()
    private var process: Process?
    private var eventHandler: CLIEventHandler?
    private var sessionId: String?
    private var pendingQuestionToolUseId: String?
    private var pendingQuestionNeedsPermissionApproval = false
    private var answeredQuestionToolUseIds: Set<String> = []
    private var allowedTools: Set<String> = []
    private var pendingDenials: [CLIPermissionDenial] = []
    private var stdoutBuffer = ""
    private var stderrBuffer = ""
    private var pendingOutput = ""
    private var hasStreamedText = false
    private var lastInput = ""
    private var isRetrying = false
    private var config: CLIConfig
    private(set) var status = "disconnected"

    init(config: CLIConfig) {
        self.config = config
        self.status = "idle"
    }

    func setEventHandler(_ handler: @escaping CLIEventHandler) {
        lock.lock()
        eventHandler = handler
        lock.unlock()
    }

    func getConfig() -> CLIConfig {
        lock.lock()
        defer { lock.unlock() }
        return config
    }

    func restoreConfig(_ input: CLIConfig) {
        lock.lock()
        config = input
        sessionId = input.cliSessionId
        lock.unlock()
    }

    func start(_ input: [String: Any]) {
        lock.lock()
        config.merge(input)
        sessionId = nil
        config.cliSessionId = nil
        pendingQuestionToolUseId = nil
        pendingQuestionNeedsPermissionApproval = false
        answeredQuestionToolUseIds.removeAll()
        pendingDenials.removeAll()
        allowedTools.removeAll()
        hasStreamedText = false
        isRetrying = false
        let nextMode = config.runMode
        let current = process
        process = nil
        lock.unlock()

        current?.terminate()

        if nextMode == "interactive" {
            spawnInteractive()
        } else {
            updateStatus("idle")
            emit(["type": "system", "content": "\(cliLabel()) 就绪 (print 模式)", "time": shortLocalTime()])
        }
    }

    func setConfirmMode(_ mode: String) {
        lock.lock()
        if mode == "key" || mode == "auto" {
            config.confirmMode = mode
        }
        lock.unlock()
    }

    func restoreSessionId(_ id: String?) {
        guard let id, id.count > 8 else { return }
        lock.lock()
        sessionId = id
        config.cliSessionId = id
        lock.unlock()
    }

    func clearSessionId() {
        lock.lock()
        sessionId = nil
        config.cliSessionId = nil
        pendingQuestionToolUseId = nil
        pendingQuestionNeedsPermissionApproval = false
        answeredQuestionToolUseIds.removeAll()
        lock.unlock()
    }

    func restoreWorkDir(_ workDir: String) {
        let resolved = WorkspacePaths.resolveAbsolute(workDir)
        var isDir = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: resolved, isDirectory: &isDir), isDir.boolValue else { return }
        lock.lock()
        config.workDir = resolved
        lock.unlock()
    }

    func sendInput(_ text: String) {
        let snapshot = getConfig()
        lock.lock()
        let currentStatus = status
        lock.unlock()

        if currentStatus == "question" {
            questionResponse(text, toolUseId: nil)
            return
        }

        if snapshot.runMode == "print", currentStatus != "confirm" {
            runPrintCommand(text, isRetry: false)
            return
        }

        guard writeToActiveProcess(text) else {
            emit(["type": "error", "content": "CLI 未连接，无法发送", "time": shortLocalTime()])
            return
        }

        if currentStatus == "confirm" || currentStatus == "idle" {
            updateStatus("running")
        }
    }

    func confirmResponse(_ approved: Bool) {
        lock.lock()
        let denials = pendingDenials
        pendingDenials.removeAll()
        let currentStatus = status
        lock.unlock()

        if approved, !denials.isEmpty {
            lock.lock()
            for denial in denials where denial.toolName != "unknown" {
                allowedTools.insert(denial.toolName)
            }
            let tools = Array(allowedTools).sorted()
            lock.unlock()

            emit(["type": "confirm_result", "approved": true, "time": shortLocalTime()])
            emit(["type": "system", "content": "已授权: \(tools.joined(separator: ", "))", "time": shortLocalTime()])
            retryWithPermission()
            return
        }

        if currentStatus == "confirm" {
            _ = writeToActiveProcess(approved ? "y" : "n")
        }
        updateStatus("idle")
        emit([
            "type": "confirm_result",
            "approved": approved,
            "time": shortLocalTime(),
        ])
    }

    func questionResponse(_ answer: String, toolUseId: String?) {
        lock.lock()
        let currentStatus = status
        let pending = pendingQuestionToolUseId
        let needsApproval = pendingQuestionNeedsPermissionApproval
        if let toolUseId, let pending, toolUseId != pending {
            lock.unlock()
            return
        }
        guard currentStatus == "question" else {
            lock.unlock()
            return
        }
        pendingQuestionToolUseId = nil
        pendingQuestionNeedsPermissionApproval = false
        if let pending {
            answeredQuestionToolUseIds.insert(pending)
        }
        lock.unlock()

        if needsApproval {
            _ = writeToActiveProcess("y")
        }
        let delivered = writeToActiveProcess(answer)

        updateStatus("running")
        emit([
            "type": "ask_question_result",
            "approved": true,
            "answer": answer,
            "toolUseId": pending ?? toolUseId ?? "",
            "time": shortLocalTime(),
        ])

        if let pending {
            emit([
                "type": "tool_call",
                "content": "用户已回答",
                "toolName": CLIManager.askUserQuestionTool,
                "status": "success",
                "details": answer,
                "toolUseId": pending,
                "time": shortLocalTime(),
            ])
        }

        if getConfig().runMode == "print", !delivered {
            runPrintCommand(buildQuestionAnswerPrompt(answer), isRetry: true)
        }
    }

    func interrupt() {
        lock.lock()
        let current = process
        let isPrintMode = config.runMode == "print"
        if isPrintMode {
            process = nil
        }
        pendingQuestionNeedsPermissionApproval = false
        lock.unlock()

        current?.interrupt()
        updateStatus("idle")
        emit(["type": "system", "content": "任务已中断", "time": shortLocalTime()])
    }

    func restart() {
        lock.lock()
        let current = process
        process = nil
        sessionId = nil
        config.cliSessionId = nil
        pendingQuestionToolUseId = nil
        pendingQuestionNeedsPermissionApproval = false
        answeredQuestionToolUseIds.removeAll()
        pendingDenials.removeAll()
        allowedTools.removeAll()
        let mode = config.runMode
        lock.unlock()

        current?.terminate()
        if mode == "interactive" {
            spawnInteractive()
        } else {
            updateStatus("idle")
            emit(["type": "system", "content": "CLI 已重置", "time": shortLocalTime()])
        }
    }

    func runOneShot(_ input: String, timeout: TimeInterval = 120) throws -> String {
        _ = timeout
        let snapshot = getConfig()
        let isolated = buildIsolatedPrintArgs(input, config: snapshot)
        let result = try Shell.run(snapshot.cliCommand, isolated.args, cwd: snapshot.workDir, input: isolated.stdin, allowExitCodes: [0])
        let parsed = extractOneShotTextAndError(from: result.stdout, cliType: snapshot.cliType)
        if !parsed.text.isEmpty { return parsed.text }
        if let errorText = parsed.error, !errorText.isEmpty {
            throw WorkspaceError.message(errorText)
        }
        let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        throw WorkspaceError.message(stderr.isEmpty ? "\(cliLabel(config: snapshot)) 未返回内容" : stderr)
    }

    private func spawnInteractive() {
        let snapshot = getConfig()
        queue.async { [weak self] in
            guard let self else { return }
            self.killProcess()
            self.lock.lock()
            self.stdoutBuffer = ""
            self.stderrBuffer = ""
            self.pendingOutput = ""
            self.lock.unlock()

            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            proc.arguments = [snapshot.cliCommand] + self.buildInteractiveArgs(config: snapshot)
            proc.currentDirectoryURL = URL(fileURLWithPath: snapshot.workDir)
            var env = ProcessInfo.processInfo.environment
            env["FORCE_COLOR"] = "0"
            env["NO_COLOR"] = "1"
            env["TERM"] = "dumb"
            proc.environment = env

            let stdout = Pipe()
            let stderr = Pipe()
            let stdin = Pipe()
            proc.standardOutput = stdout
            proc.standardError = stderr
            proc.standardInput = stdin

            stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
                guard let self else { return }
                let data = handle.availableData
                guard !data.isEmpty else { return }
                self.handleStdout(String(data: data, encoding: .utf8) ?? "")
            }

            stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
                guard let self else { return }
                let data = handle.availableData
                guard !data.isEmpty else { return }
                self.handleStderr(String(data: data, encoding: .utf8) ?? "")
            }

            proc.terminationHandler = { [weak self, weak proc] process in
                guard let self else { return }
                stdout.fileHandleForReading.readabilityHandler = nil
                stderr.fileHandleForReading.readabilityHandler = nil
                self.flushPendingOutput()
                self.lock.lock()
                if self.process === proc {
                    self.process = nil
                }
                self.lock.unlock()
                self.updateStatus("disconnected")
                self.emit(["type": "system", "content": "CLI 进程已退出 (code: \(process.terminationStatus))", "time": shortLocalTime()])
            }

            do {
                try proc.run()
                self.lock.lock()
                self.process = proc
                self.lock.unlock()
                self.updateStatus("idle")
                self.emit(["type": "system", "content": "CLI 进程已启动 (交互模式)", "time": shortLocalTime()])
            } catch {
                stdout.fileHandleForReading.readabilityHandler = nil
                stderr.fileHandleForReading.readabilityHandler = nil
                self.emit(["type": "error", "content": "\(self.cliLabel(config: snapshot)) 启动失败: \(error.localizedDescription)", "time": shortLocalTime()])
                self.updateStatus("disconnected")
            }
        }
    }

    private func runPrintCommand(_ input: String, isRetry: Bool) {
        let snapshot = getConfig()
        guard snapshot.runMode == "print" else {
            emit(["type": "error", "content": "当前会话处于交互模式，无法使用 print 调用", "time": shortLocalTime()])
            return
        }

        queue.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            if !isRetry { self.lastInput = input }
            self.pendingDenials.removeAll()
            self.hasStreamedText = false
            self.isRetrying = isRetry
            self.lock.unlock()
            self.updateStatus("running")

            let built = self.buildPrintArgs(input, config: snapshot)
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            proc.arguments = [snapshot.cliCommand] + built.args
            proc.currentDirectoryURL = URL(fileURLWithPath: snapshot.workDir)
            var env = ProcessInfo.processInfo.environment
            env["FORCE_COLOR"] = "0"
            env["NO_COLOR"] = "1"
            proc.environment = env

            let stdout = Pipe()
            let stderr = Pipe()
            let stdin = Pipe()
            proc.standardOutput = stdout
            proc.standardError = stderr
            proc.standardInput = stdin

            let outputBuffer = CLIOutputBuffer()

            stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
                guard let self else { return }
                let data = handle.availableData
                guard !data.isEmpty else { return }
                let text = String(data: data, encoding: .utf8) ?? ""
                let lines = outputBuffer.appendStdout(text)
                for line in lines {
                    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { continue }
                    if self.consumeOutputLine(trimmed, cliType: snapshot.cliType) {
                        outputBuffer.markStructuredError()
                    }
                }
            }

            stderr.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                outputBuffer.appendStderr(String(data: data, encoding: .utf8) ?? "")
            }

            proc.terminationHandler = { [weak self, weak proc] process in
                guard let self else { return }
                stdout.fileHandleForReading.readabilityHandler = nil
                stderr.fileHandleForReading.readabilityHandler = nil
                let snapshotOutput = outputBuffer.snapshot()
                let remaining = snapshotOutput.remaining
                let errorText = snapshotOutput.stderr
                if !remaining.isEmpty, self.consumeOutputLine(remaining, cliType: snapshot.cliType) {
                    outputBuffer.markStructuredError()
                }
                let hasStructuredError = outputBuffer.snapshot().hasStructuredError
                if process.terminationStatus != 0, !errorText.isEmpty, !hasStructuredError {
                    for line in errorText.components(separatedBy: .newlines) where !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        self.emit(["type": "error", "content": line.trimmingCharacters(in: .whitespacesAndNewlines), "time": shortLocalTime()])
                    }
                }
                self.lock.lock()
                if self.process === proc {
                    self.process = nil
                }
                let shouldIdle = self.status != "confirm" && self.status != "question"
                self.isRetrying = false
                self.lock.unlock()
                if shouldIdle {
                    self.updateStatus("idle")
                }
            }

            do {
                try proc.run()
                self.lock.lock()
                self.process = proc
                self.lock.unlock()
                if let stdinText = built.stdin {
                    stdin.fileHandleForWriting.write(Data(stdinText.utf8))
                }
                try? stdin.fileHandleForWriting.close()
            } catch {
                stdout.fileHandleForReading.readabilityHandler = nil
                stderr.fileHandleForReading.readabilityHandler = nil
                self.lock.lock()
                self.isRetrying = false
                self.lock.unlock()
                self.emit(["type": "error", "content": "\(self.cliLabel(config: snapshot)) 启动失败: \(error.localizedDescription)", "time": shortLocalTime()])
                self.updateStatus("idle")
            }
        }
    }

    private func retryWithPermission() {
        guard getSessionId() != nil else {
            emit(["type": "error", "content": "无法重试: 没有活跃的会话", "time": shortLocalTime()])
            updateStatus("idle")
            return
        }
        let tools = allowedToolsSnapshot(includeAskQuestion: false).joined(separator: ", ")
        emit(["type": "system", "content": "正在恢复会话并重试 (已授权: \(tools))...", "time": shortLocalTime()])
        runPrintCommand("请继续之前的操作，现在已经有权限了，请重新执行之前被拒绝的步骤。", isRetry: true)
    }

    private func consumeOutputLine(_ line: String, cliType: String) -> Bool {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            if cliType != "codex" {
                emit(["type": "ai_message", "content": stripAnsi(line), "time": shortLocalTime()])
            }
            return false
        }
        let eventType = json["type"] as? String ?? ""
        handleJSONMessage(json, cliType: cliType)
        return eventType == "error" || eventType == "turn.failed"
    }

    private func handleStdout(_ data: String) {
        let clean = stripAnsi(data)
        lock.lock()
        stdoutBuffer += clean
        let lines = stdoutBuffer.components(separatedBy: "\n")
        stdoutBuffer = lines.last ?? ""
        lock.unlock()

        for line in lines.dropLast() {
            processLine(line.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    private func handleStderr(_ data: String) {
        let clean = stripAnsi(data)
        lock.lock()
        stderrBuffer += clean
        let lines = stderrBuffer.components(separatedBy: "\n")
        stderrBuffer = lines.last ?? ""
        lock.unlock()

        for line in lines.dropLast() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                emit(["type": "error", "content": trimmed, "time": shortLocalTime()])
            }
        }
    }

    private func processLine(_ line: String) {
        guard !line.isEmpty else { return }
        if let data = line.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            handleJSONMessage(json, cliType: getConfig().cliType)
            return
        }

        if isPromptLine(line) {
            flushPendingOutput()
            updateStatus("idle")
            return
        }

        if CLIManager.confirmPatterns.contains(where: { line.range(of: $0, options: .regularExpression) != nil }) {
            flushPendingOutput()
            handleConfirmation(promptText: line, permission: nil)
            return
        }

        lock.lock()
        pendingOutput += (pendingOutput.isEmpty ? "" : "\n") + line
        lock.unlock()
    }

    private func isPromptLine(_ line: String) -> Bool {
        line.range(of: #"^\s*>\s*$"#, options: .regularExpression) != nil ||
        line.range(of: #"^\s*›\s*$"#, options: .regularExpression) != nil ||
        line.range(of: #"^\s*\$\s*$"#, options: .regularExpression) != nil
    }

    private func flushPendingOutput() {
        lock.lock()
        let text = pendingOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        pendingOutput = ""
        let shouldEmit = !text.isEmpty && (status == "idle" || status == "running")
        if shouldEmit {
            status = "running"
        }
        lock.unlock()

        guard shouldEmit else { return }
        emit(["type": "status", "status": "running"])
        emit(["type": "ai_message", "content": text, "time": shortLocalTime()])
    }

    private func handleJSONMessage(_ msg: [String: Any], cliType: String) {
        if cliType == "codex", handleCodexJSONMessage(msg) {
            return
        }

        let type = msg["type"] as? String ?? ""
        switch type {
        case "system":
            handleSystemMessage(msg)

        case "assistant", "text", "content_block_delta":
            updateStatus("running")
            if type == "content_block_delta",
               let delta = msg["delta"] as? [String: Any],
               delta["type"] as? String == "thinking_delta",
               let thinking = delta["thinking"] as? String,
               !thinking.isEmpty {
                emit(["type": "thinking_message", "content": thinking, "time": shortLocalTime()])
                return
            }

            let message = msg["message"] as? [String: Any] ?? msg
            if let blocks = message["content"] as? [Any] {
                if handleContentBlocks(blocks) { return }
            } else if let text = extractText(msg["delta"] ?? msg["content"] ?? msg["message"] ?? msg["text"]), !text.isEmpty {
                markStreamedText()
                emit(["type": "ai_message", "content": text, "time": shortLocalTime()])
            }

        case "content_block_start":
            if let block = msg["content_block"] as? [String: Any] {
                updateStatus("running")
                _ = handleContentBlock(block)
            }

        case "content_block_stop":
            break

        case "tool_use", "tool":
            updateStatus("running")
            let name = msg["name"] as? String ?? "tool"
            let input = msg["input"]
            let id = msg["id"] as? String
            emitToolCall(name: name, input: input, toolUseId: id)
            if name == CLIManager.askUserQuestionTool, handleAskUserQuestion(input: input, toolUseId: id) {
                return
            }

        case "user":
            let message = msg["message"] as? [String: Any] ?? msg
            if let blocks = message["content"] as? [Any] {
                for block in blocks {
                    guard let dict = block as? [String: Any], dict["type"] as? String == "tool_result" else { continue }
                    handleToolResult(
                        toolUseId: dict["tool_use_id"] as? String,
                        isError: (dict["is_error"] as? Bool) ?? false,
                        details: extractText(dict["content"]) ?? "",
                        toolName: msg["tool_name"] as? String,
                        input: msg["tool_input"] as? [String: Any] ?? [:]
                    )
                }
            }

        case "tool_result":
            let details = extractText(msg["content"]) ?? ""
            handleToolResult(
                toolUseId: msg["tool_use_id"] as? String,
                isError: (msg["is_error"] as? Bool) ?? false,
                details: details,
                toolName: msg["tool_name"] as? String,
                input: msg["tool_input"] as? [String: Any] ?? [:]
            )

        case "permission_request":
            handlePermissionRequest(msg)

        case "confirm", "approval_request":
            handleConfirmation(
                promptText: extractText(msg["message"] ?? msg["content"] ?? msg["prompt"]) ?? "CLI 请求确认",
                permission: nil
            )

        case "result", "done", "complete":
            handleResultMessage(msg)

        case "error", "turn.failed":
            emit(["type": "error", "content": extractText(msg["error"] ?? msg["message"] ?? msg["content"]) ?? "\(cliLabel()) 执行失败", "time": shortLocalTime()])
            updateStatus("idle")

        default:
            if let text = extractText(msg["content"] ?? msg["message"] ?? msg["text"]), !text.isEmpty {
                updateStatus("running")
                emit(["type": "ai_message", "content": text, "time": shortLocalTime()])
            }
        }
    }

    private func handleSystemMessage(_ msg: [String: Any]) {
        let inner = tryParseJSONObject(msg["content"]) ?? msg
        let sid = (msg["session_id"] ?? inner["session_id"] ?? msg["id"] ?? inner["id"]) as? String
        if let sid, sid.count > 8 {
            restoreSessionId(sid)
        }

        if inner["subtype"] as? String == "init" {
            var details: [String: Any] = ["subtype": "init"]
            if let model = inner["model"] ?? msg["model"] { details["model"] = model }
            if let session = inner["session_id"] { details["session_id"] = session }
            if let tools = inner["tools"] as? [Any], !tools.isEmpty { details["toolsCount"] = tools.count }
            let sessionPreview = String((sid ?? "").prefix(8))
            let content = isRetrying
                ? "会话已恢复 (session: \(sessionPreview)...)"
                : "CLI 已初始化 (session: \(sessionPreview)...)"
            emit(["type": "system", "content": content, "time": shortLocalTime(), "details": details])
            return
        }

        var details: [String: Any] = [:]
        let usage = inner["usage"] as? [String: Any] ?? [:]
        if let subtype = inner["subtype"] { details["subtype"] = subtype }
        if let model = inner["model"] { details["model"] = model }
        if let session = inner["session_id"] { details["session_id"] = session }
        if let tools = inner["tools"] as? [Any] { details["toolsCount"] = tools.count }
        if let cost = inner["total_cost_usd"] ?? inner["cost_usd"] { details["costUsd"] = cost }
        if let duration = inner["duration_ms"] { details["durationMs"] = duration }
        if let turns = inner["num_turns"] { details["numTurns"] = turns }
        if let value = usage["input_tokens"] ?? inner["input_tokens"] { details["inputTokens"] = value }
        if let value = usage["output_tokens"] ?? inner["output_tokens"] { details["outputTokens"] = value }
        if let value = usage["cache_read_input_tokens"] { details["cacheReadTokens"] = value }
        if let value = usage["cache_creation_input_tokens"] { details["cacheCreationTokens"] = value }

        var content = extractText(msg["message"] ?? inner["message"] ?? inner["content"]) ?? ""
        if content.isEmpty {
            if details["subtype"] as? String == "result" {
                content = "执行完成"
            } else if let subtype = details["subtype"] as? String, !subtype.isEmpty {
                let labels = ["status": "状态更新", "error": "系统错误", "warning": "系统警告", "info": "系统通知"]
                content = labels[subtype] ?? "系统事件: \(subtype)"
            } else {
                var parts: [String] = []
                if let model = inner["model"] { parts.append("模型 \(model)") }
                if let count = details["toolsCount"] { parts.append("\(count) 个工具") }
                if let sid { parts.append("session \(String(sid.prefix(8)))...") }
                content = parts.isEmpty ? "系统消息" : parts.joined(separator: " · ")
            }
        }

        var event: [String: Any] = ["type": "system", "content": content, "time": shortLocalTime()]
        if !details.isEmpty { event["details"] = details }
        emit(event)
    }

    private func handleResultMessage(_ msg: [String: Any]) {
        if let sid = (msg["session_id"] ?? msg["id"]) as? String, sid.count > 8 {
            restoreSessionId(sid)
        }

        var denials = pendingDenialsSnapshot()
        if let rawDenials = msg["permission_denials"] as? [Any] {
            denials.append(contentsOf: rawDenials.compactMap { parseDenial($0) })
        }
        denials = denials.filter { !shouldIgnoreAskUserQuestionDenial(toolName: $0.toolName, toolUseId: $0.toolUseId) }

        if !denials.isEmpty, getConfig().confirmMode != "auto" {
            lock.lock()
            pendingDenials = denials
            lock.unlock()
            updateStatus("confirm")
            emitConfirmRequest(for: denials[0])
        } else {
            lock.lock()
            let isQuestion = status == "question"
            lock.unlock()
            if !isQuestion {
                updateStatus("idle")
            }
        }

        let text = extractText(msg["content"] ?? msg["message"] ?? msg["result"])
        lock.lock()
        let shouldEmitText = !hasStreamedText
        hasStreamedText = false
        lock.unlock()
        if shouldEmitText, let text, !text.isEmpty {
            emit(["type": "ai_message", "content": text, "time": shortLocalTime()])
        }

        var details: [String: Any] = ["subtype": "result"]
        let usage = msg["usage"] as? [String: Any] ?? [:]
        if let sid = msg["session_id"] { details["session_id"] = sid }
        if let cost = msg["total_cost_usd"] ?? msg["cost_usd"] { details["costUsd"] = cost }
        if let duration = msg["duration_ms"] { details["durationMs"] = duration }
        if let duration = msg["duration_api_ms"] { details["durationApiMs"] = duration }
        if let turns = msg["num_turns"] { details["numTurns"] = turns }
        if let model = msg["model"] {
            details["model"] = model
        } else if let modelUsage = msg["modelUsage"] as? [String: Any], let first = modelUsage.keys.first {
            details["model"] = first
        }
        if let value = usage["input_tokens"] ?? msg["input_tokens"] { details["inputTokens"] = value }
        if let value = usage["output_tokens"] ?? msg["output_tokens"] { details["outputTokens"] = value }
        if let value = usage["cache_read_input_tokens"] { details["cacheReadTokens"] = value }
        if let value = usage["cache_creation_input_tokens"] { details["cacheCreationTokens"] = value }
        emit(["type": "system", "content": "执行完成", "time": shortLocalTime(), "details": details])
    }

    private func handleContentBlocks(_ blocks: [Any]) -> Bool {
        for block in blocks {
            guard let dict = block as? [String: Any] else { continue }
            if handleContentBlock(dict) { return true }
        }
        return false
    }

    private func handleContentBlock(_ block: [String: Any]) -> Bool {
        let type = block["type"] as? String ?? ""
        if type == "tool_use" {
            let name = block["name"] as? String ?? "tool"
            let input = block["input"]
            let id = block["id"] as? String
            emitToolCall(name: name, input: input, toolUseId: id)
            if name == CLIManager.askUserQuestionTool {
                return handleAskUserQuestion(input: input, toolUseId: id)
            }
        } else if type == "text", let text = block["text"] as? String, !text.isEmpty {
            markStreamedText()
            emit(["type": "ai_message", "content": text, "time": shortLocalTime()])
        } else if type == "thinking", let thinking = block["thinking"] as? String, !thinking.isEmpty {
            emit(["type": "thinking_message", "content": thinking, "time": shortLocalTime()])
        }
        return false
    }

    private func emitToolCall(name: String, input: Any?, toolUseId: String?) {
        emit([
            "type": "tool_call",
            "content": name,
            "toolName": name,
            "status": "running",
            "details": input.map { JSONSupport.string($0) } ?? "",
            "toolUseId": toolUseId ?? "",
            "time": shortLocalTime(),
        ])
    }

    private func handleToolResult(toolUseId: String?, isError: Bool, details: String, toolName rawToolName: String?, input: [String: Any]) {
        if let toolUseId, answeredQuestionToolUseIdsSnapshot().contains(toolUseId) {
            return
        }

        if isError, isPermissionDenial(details) {
            let toolName = rawToolName ?? extractToolNameFromDenial(details)
            if shouldIgnoreAskUserQuestionDenial(toolName: toolName, toolUseId: toolUseId) {
                return
            }
            let denial = CLIPermissionDenial(
                toolName: toolName,
                category: getToolCategory(toolName),
                toolUseId: toolUseId,
                input: input,
                description: details
            )
            lock.lock()
            pendingDenials.append(denial)
            lock.unlock()
            emit([
                "type": "tool_call",
                "content": "权限被拒绝: \(toolName)",
                "toolName": toolName,
                "status": "failed",
                "details": details,
                "toolUseId": toolUseId ?? "",
                "time": shortLocalTime(),
            ])
            return
        }

        emit([
            "type": "tool_call",
            "content": isError ? "工具执行失败" : "工具执行完成",
            "toolName": toolUseId ?? "result",
            "status": isError ? "failed" : "success",
            "details": details,
            "toolUseId": toolUseId ?? "",
            "time": shortLocalTime(),
        ])
    }

    private func handlePermissionRequest(_ msg: [String: Any]) {
        let toolName = (msg["tool_name"] ?? msg["toolName"] ?? msg["name"]) as? String ?? "unknown"
        if toolName == CLIManager.askUserQuestionTool {
            lock.lock()
            allowedTools.insert(CLIManager.askUserQuestionTool)
            lock.unlock()
            let handled = handleAskUserQuestion(input: msg["input"] ?? msg["tool_input"] ?? [:], toolUseId: (msg["tool_use_id"] ?? msg["toolUseId"] ?? msg["id"]) as? String)
            lock.lock()
            pendingQuestionNeedsPermissionApproval = handled && config.runMode != "print"
            lock.unlock()
            return
        }

        if getConfig().confirmMode == "auto" {
            _ = writeToActiveProcess("y")
            emit(["type": "system", "content": "已自动批准操作", "time": shortLocalTime()])
            return
        }

        let input = msg["input"] as? [String: Any] ?? msg["tool_input"] as? [String: Any] ?? [:]
        let description = extractText(msg["description"] ?? msg["message"] ?? msg["content"]) ?? ""
        updateStatus("confirm")
        emit([
            "type": "confirm_request",
            "content": description.isEmpty ? "\(toolName) 请求权限" : description,
            "time": shortLocalTime(),
            "permission": permissionPayload(toolName: toolName, input: input, description: description),
        ])
    }

    private func handleConfirmation(promptText: String, permission: [String: Any]?) {
        if getConfig().confirmMode == "auto" {
            _ = writeToActiveProcess("y")
            emit(["type": "system", "content": "已自动批准操作", "time": shortLocalTime()])
            return
        }

        updateStatus("confirm")
        var event: [String: Any] = [
            "type": "confirm_request",
            "content": promptText,
            "time": shortLocalTime(),
        ]
        if let permission { event["permission"] = permission }
        emit(event)
    }

    @discardableResult
    private func handleAskUserQuestion(input: Any?, toolUseId: String?) -> Bool {
        let questions = normalizeAskUserQuestions(input)
        guard !questions.isEmpty else { return false }

        lock.lock()
        if let toolUseId, pendingQuestionToolUseId == toolUseId {
            let alreadyQuestion = status == "question"
            lock.unlock()
            if !alreadyQuestion {
                updateStatus("question")
            }
            return true
        }
        pendingQuestionToolUseId = toolUseId
        pendingQuestionNeedsPermissionApproval = false
        lock.unlock()

        updateStatus("question")
        emit([
            "type": "ask_question",
            "content": "Agent 提出问题",
            "questions": questions,
            "toolUseId": toolUseId ?? "",
            "time": shortLocalTime(),
        ])
        pausePrintProcessForQuestion()
        return true
    }

    private func pausePrintProcessForQuestion() {
        guard getConfig().runMode == "print" else { return }
        lock.lock()
        let current = process
        process = nil
        lock.unlock()
        current?.interrupt()
    }

    private func handleCodexJSONMessage(_ msg: [String: Any]) -> Bool {
        let type = msg["type"] as? String ?? ""
        switch type {
        case "thread.started":
            if let threadId = (msg["thread_id"] ?? msg["threadId"]) as? String {
                restoreSessionId(threadId)
                emit([
                    "type": "system",
                    "content": "Codex CLI 已初始化 (thread: \(String(threadId.prefix(8)))...)",
                    "time": shortLocalTime(),
                    "details": ["subtype": "init", "session_id": threadId],
                ])
            }
            return true
        case "turn.started":
            updateStatus("running")
            return true
        case "turn.completed":
            emitCodexUsage(msg["usage"])
            lock.lock()
            let shouldIdle = status != "confirm" && status != "question"
            hasStreamedText = false
            lock.unlock()
            if shouldIdle {
                updateStatus("idle")
            }
            return true
        case "turn.failed", "error":
            emit(["type": "error", "content": extractText(msg["error"] ?? msg["message"] ?? msg["content"]) ?? "Codex CLI 执行失败", "time": shortLocalTime()])
            lock.lock()
            let shouldIdle = status != "confirm" && status != "question"
            lock.unlock()
            if shouldIdle {
                updateStatus("idle")
            }
            return true
        case "item.started", "item.completed":
            guard let item = msg["item"] as? [String: Any] else { return true }
            let itemType = item["type"] as? String ?? "item"
            let isCompleted = type == "item.completed"
            let itemId = item["id"] as? String

            if itemType == "command_execution" {
                let command = item["command"] as? String ?? "command"
                let output = item["aggregated_output"] as? String ?? ""
                let exitCode = item["exit_code"] as? Int
                emit([
                    "type": "tool_call",
                    "content": command,
                    "toolName": "Shell",
                    "status": isCompleted ? ((exitCode ?? 0) == 0 ? "success" : "failed") : "running",
                    "details": isCompleted ? (output.isEmpty ? "exit code: \(exitCode ?? 0)" : output) : command,
                    "toolUseId": itemId ?? "",
                    "time": shortLocalTime(),
                ])
                return true
            }

            let isAgentMessage = itemType == "agent_message" || itemType == "assistant_message" || (itemType == "message" && item["role"] as? String == "assistant")
            if isCompleted, isAgentMessage {
                if let text = extractText(item["text"] ?? item["content"] ?? item["message"] ?? item), !text.isEmpty {
                    markStreamedText()
                    emit(["type": "ai_message", "content": text, "time": shortLocalTime()])
                }
                return true
            }

            if isCompleted, itemType == "reasoning" || itemType == "thinking" {
                if let text = extractText(item["text"] ?? item["content"] ?? item["message"]), !text.isEmpty {
                    emit(["type": "thinking_message", "content": text, "time": shortLocalTime()])
                }
                return true
            }
            return true
        default:
            return type.contains(".")
        }
    }

    private func emitCodexUsage(_ usage: Any?) {
        guard let usage = usage as? [String: Any] else { return }
        var details: [String: Any] = ["subtype": "result"]
        if let value = usage["input_tokens"] { details["inputTokens"] = value }
        if let value = usage["output_tokens"] { details["outputTokens"] = value }
        if let value = usage["cached_input_tokens"] { details["cacheReadTokens"] = value }
        if let value = usage["reasoning_output_tokens"] { details["reasoningOutputTokens"] = value }
        if let sid = getSessionId() { details["session_id"] = sid }
        guard details.count > 1 else { return }
        emit(["type": "system", "content": "执行完成", "time": shortLocalTime(), "details": details])
    }

    private func buildPrintArgs(_ input: String, config: CLIConfig) -> (args: [String], stdin: String?) {
        if config.cliType == "codex" {
            var args = config.cliArgs
            if !hasArg(args, shortName: "-C", longName: "--cd") {
                args.append(contentsOf: ["-C", config.workDir])
            }
            args.append("exec")
            if let sessionId = getSessionId() {
                args.append(contentsOf: ["resume", "--json", sessionId, "-"])
            } else {
                args.append(contentsOf: ["--json", "-"])
            }
            return (args, input)
        }

        var args = config.cliArgs
        if let sessionId = getSessionId() {
            args.append(contentsOf: ["--resume", sessionId])
        }
        args.append(contentsOf: ["-p", input, "--output-format", "stream-json", "--verbose"])
        let tools = allowedToolsSnapshot(includeAskQuestion: true)
        if !tools.isEmpty {
            args.append(contentsOf: ["--allowedTools", tools.joined(separator: ",")])
        }
        return (args, nil)
    }

    private func buildIsolatedPrintArgs(_ input: String, config: CLIConfig) -> (args: [String], stdin: String?) {
        if config.cliType == "codex" {
            var args = config.cliArgs
            if !hasArg(args, shortName: "-C", longName: "--cd") {
                args.append(contentsOf: ["-C", config.workDir])
            }
            args.append(contentsOf: ["exec", "--json", "-"])
            return (args, input)
        }
        var args = config.cliArgs
        args.append(contentsOf: ["-p", input, "--output-format", "stream-json", "--verbose"])
        return (args, nil)
    }

    private func buildInteractiveArgs(config: CLIConfig) -> [String] {
        var args = config.cliArgs
        if config.cliType == "codex" {
            if !hasArg(args, shortName: "-C", longName: "--cd") {
                args.append(contentsOf: ["-C", config.workDir])
            }
            if !args.contains("--no-alt-screen") {
                args.append("--no-alt-screen")
            }
        }
        return args
    }

    private func extractOneShotTextAndError(from output: String, cliType: String) -> (text: String, error: String?) {
        var texts: [String] = []
        var errors: [String] = []
        for line in output.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if let data = trimmed.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let error = oneShotError(json), !error.isEmpty {
                    errors.append(error)
                }
                if let text = oneShotText(json), !text.isEmpty {
                    texts.append(text)
                }
            } else if cliType != "codex" {
                texts.append(trimmed)
            }
        }
        let text = (texts.last ?? texts.joined(separator: "\n")).trimmingCharacters(in: .whitespacesAndNewlines)
        return (text, errors.first)
    }

    private func oneShotText(_ msg: [String: Any]) -> String? {
        let type = msg["type"] as? String ?? ""
        if type == "item.completed", let item = msg["item"] as? [String: Any] {
            let itemType = item["type"] as? String ?? ""
            let isAgentMessage = itemType == "agent_message" || itemType == "assistant_message" || (itemType == "message" && item["role"] as? String == "assistant")
            return isAgentMessage ? extractText(item["text"] ?? item["content"] ?? item["message"] ?? item) : nil
        }
        if ["assistant", "text", "result", "done", "complete"].contains(type) {
            return extractText(msg["message"] ?? msg["content"] ?? msg["result"] ?? msg["text"])
        }
        if type == "content_block_delta" {
            return extractText(msg["delta"])
        }
        return nil
    }

    private func oneShotError(_ msg: [String: Any]) -> String? {
        let type = msg["type"] as? String ?? ""
        guard type == "error" || type == "turn.failed" else { return nil }
        return extractText(msg["error"] ?? msg["message"] ?? msg["content"]) ?? "\(cliLabel()) 执行失败"
    }

    private func normalizeQuestionOptions(_ options: Any?) -> [[String: Any]] {
        guard let options = options as? [Any] else { return [] }
        return options.compactMap { option -> [String: Any]? in
            if let label = option as? String, !label.isEmpty {
                return ["label": label]
            }
            guard let dict = option as? [String: Any],
                  let label = dict["label"] as? String,
                  !label.isEmpty else { return nil }
            var result: [String: Any] = ["label": label]
            if let description = dict["description"] as? String { result["description"] = description }
            if let markdown = dict["markdown"] as? String { result["markdown"] = markdown }
            return result
        }
    }

    private func normalizeAskUserQuestions(_ input: Any?) -> [[String: Any]] {
        guard let dict = input as? [String: Any] else { return [] }
        if let rawQuestions = dict["questions"] as? [Any] {
            return rawQuestions.compactMap { item -> [String: Any]? in
                if let question = item as? String, !question.isEmpty {
                    return ["question": question, "options": []]
                }
                guard let raw = item as? [String: Any],
                      let question = raw["question"] as? String,
                      !question.isEmpty else { return nil }
                var result: [String: Any] = [
                    "question": question,
                    "options": normalizeQuestionOptions(raw["options"]),
                    "multiSelect": (raw["multiSelect"] as? Bool) ?? false,
                ]
                if let header = raw["header"] as? String { result["header"] = header }
                return result
            }
        }

        if let question = dict["question"] as? String, !question.isEmpty {
            var result: [String: Any] = [
                "question": question,
                "options": normalizeQuestionOptions(dict["options"]),
                "multiSelect": (dict["multiSelect"] as? Bool) ?? false,
            ]
            if let header = dict["header"] as? String { result["header"] = header }
            return [result]
        }

        return []
    }

    private func permissionPayload(toolName: String, input: [String: Any], description: String) -> [String: Any] {
        let category = getToolCategory(toolName)
        var filePath = ""
        var command = ""
        var diffContent = ""

        if category == "file" {
            filePath = (input["file_path"] ?? input["path"] ?? input["filename"]) as? String ?? ""
            if let content = input["content"] {
                diffContent = content as? String ?? JSONSupport.string(content)
            }
            if input["old_string"] != nil || input["new_string"] != nil {
                diffContent = ""
                if let old = input["old_string"] { diffContent += "--- 原内容\n\(old)\n" }
                if let new = input["new_string"] { diffContent += "+++ 新内容\n\(new)\n" }
            }
        } else if category == "command" {
            command = (input["command"] ?? input["cmd"]) as? String ?? ""
        }

        var payload: [String: Any] = [
            "toolName": toolName,
            "category": category,
            "filePath": filePath,
            "command": command,
            "diffContent": diffContent,
            "description": description,
        ]
        if !input.isEmpty { payload["input"] = input }
        return payload
    }

    private func emitConfirmRequest(for denial: CLIPermissionDenial) {
        emit([
            "type": "confirm_request",
            "content": "\(denial.toolName) 请求权限: \(denial.description.isEmpty ? denial.toolUseId ?? "" : denial.description)",
            "time": shortLocalTime(),
            "permission": permissionPayload(toolName: denial.toolName, input: denial.input, description: denial.description),
        ])
    }

    private func parseDenial(_ value: Any) -> CLIPermissionDenial? {
        guard let dict = value as? [String: Any] else { return nil }
        let description = extractText(dict["description"] ?? dict["message"] ?? dict["content"]) ?? ""
        let toolName = (dict["tool_name"] ?? dict["toolName"]) as? String ?? extractToolNameFromDenial(description)
        let input = dict["tool_input"] as? [String: Any] ?? dict["input"] as? [String: Any] ?? [:]
        let toolUseId = (dict["tool_use_id"] ?? dict["toolUseId"]) as? String
        return CLIPermissionDenial(
            toolName: toolName,
            category: getToolCategory(toolName),
            toolUseId: toolUseId,
            input: input,
            description: description
        )
    }

    private func buildQuestionAnswerPrompt(_ answer: String) -> String {
        [
            "用户刚刚回答了你通过 AskUserQuestion 提出的问题。",
            "请将下面内容作为该问题的用户答案，并继续之前的任务。",
            "",
            "用户回答：\(answer)",
        ].joined(separator: "\n")
    }

    private func extractToolNameFromDenial(_ text: String) -> String {
        let patterns = [
            #"(?i)permissions?\s+to\s+(?:use|call|run|execute)\s+([A-Za-z0-9_.:-]+)"#,
            #"(?i)permissions?\s+(?:to|for)\s+([A-Za-z0-9_.:-]+)"#,
            #"(?i)tool\s+([A-Za-z0-9_.:-]+)"#,
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  match.numberOfRanges > 1,
                  let range = Range(match.range(at: 1), in: text) else { continue }
            return String(text[range])
        }
        return "unknown"
    }

    private func isPermissionDenial(_ details: String) -> Bool {
        details.range(of: #"(?i)requested permissions"#, options: .regularExpression) != nil
    }

    private func shouldIgnoreAskUserQuestionDenial(toolName: String, toolUseId: String?) -> Bool {
        if toolName == CLIManager.askUserQuestionTool { return true }
        lock.lock()
        let pending = pendingQuestionToolUseId
        lock.unlock()
        return toolUseId != nil && pending != nil && toolUseId == pending
    }

    private func getToolCategory(_ toolName: String) -> String {
        if CLIManager.fileTools.contains(toolName) { return "file" }
        if CLIManager.commandTools.contains(toolName) { return "command" }
        return "other"
    }

    private func extractText(_ value: Any?) -> String? {
        guard let value else { return nil }
        if let string = value as? String { return string }
        if let array = value as? [Any] {
            let text = array.compactMap { item -> String? in
                if let string = item as? String { return string }
                if let dict = item as? [String: Any] {
                    return dict["text"] as? String ?? dict["content"] as? String ?? dict["thinking"] as? String
                }
                return nil
            }.joined(separator: "\n")
            return text.isEmpty ? nil : text
        }
        if let dict = value as? [String: Any] {
            if let content = dict["content"] as? [Any] {
                return extractText(content)
            }
            return dict["text"] as? String ?? dict["message"] as? String ?? dict["content"] as? String ?? dict["thinking"] as? String
        }
        return String(describing: value)
    }

    private func tryParseJSONObject(_ value: Any?) -> [String: Any]? {
        guard let string = value as? String,
              let data = string.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object
    }

    private func markStreamedText() {
        lock.lock()
        hasStreamedText = true
        lock.unlock()
    }

    private func pendingDenialsSnapshot() -> [CLIPermissionDenial] {
        lock.lock()
        defer { lock.unlock() }
        return pendingDenials
    }

    private func answeredQuestionToolUseIdsSnapshot() -> Set<String> {
        lock.lock()
        defer { lock.unlock() }
        return answeredQuestionToolUseIds
    }

    private func allowedToolsSnapshot(includeAskQuestion: Bool) -> [String] {
        lock.lock()
        var tools = allowedTools
        lock.unlock()
        if includeAskQuestion {
            tools.insert(CLIManager.askUserQuestionTool)
        }
        return Array(tools).sorted()
    }

    private func hasArg(_ args: [String], shortName: String, longName: String) -> Bool {
        args.contains { $0 == shortName || $0 == longName || $0.hasPrefix("\(longName)=") }
    }

    private func getSessionId() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return sessionId
    }

    private func writeToActiveProcess(_ text: String) -> Bool {
        lock.lock()
        let target = process
        lock.unlock()
        guard let pipe = target?.standardInput as? Pipe else { return false }
        pipe.fileHandleForWriting.write(Data((text + "\n").utf8))
        return true
    }

    private func killProcess() {
        lock.lock()
        let current = process
        process = nil
        lock.unlock()
        current?.terminate()
    }

    private func updateStatus(_ next: String) {
        lock.lock()
        status = next
        lock.unlock()
        emit(["type": "status", "status": next])
    }

    private func emit(_ event: [String: Any]) {
        lock.lock()
        let handler = eventHandler
        lock.unlock()
        handler?(event)
    }

    private func cliLabel(config: CLIConfig? = nil) -> String {
        let type = config?.cliType ?? getConfig().cliType
        return type == "codex" ? "Codex CLI" : "Claude CLI"
    }

    private func stripAnsi(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{001B}\\[[0-9;]*[a-zA-Z]|\u{001B}\\].*?(?:\u{0007}|\u{001B}\\\\)|\r", with: "", options: .regularExpression)
    }
}
