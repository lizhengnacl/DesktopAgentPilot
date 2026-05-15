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

final class CLIManager: @unchecked Sendable {
    private let queue = DispatchQueue(label: "desktop-agentpilot.cli")
    private let lock = NSRecursiveLock()
    private var process: Process?
    private var eventHandler: CLIEventHandler?
    private var sessionId: String?
    private var pendingQuestionToolUseId: String?
    private var hasStreamedText = false
    private var lastInput = ""
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
        status = config.runMode == "interactive" ? "disconnected" : "idle"
        lock.unlock()

        emit(["type": "status", "status": status])
        emit(["type": "system", "content": "\(cliLabel()) 就绪 (print 模式)", "time": shortLocalTime()])
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
        lock.lock()
        let currentStatus = status
        lock.unlock()
        if currentStatus == "question" {
            questionResponse(text, toolUseId: nil)
            return
        }
        runPrintCommand(text, isRetry: false)
    }

    func confirmResponse(_ approved: Bool) {
        updateStatus("idle")
        emit([
            "type": "confirm_result",
            "approved": approved,
            "time": shortLocalTime(),
        ])
    }

    func questionResponse(_ answer: String, toolUseId: String?) {
        lock.lock()
        let pending = pendingQuestionToolUseId
        pendingQuestionToolUseId = nil
        lock.unlock()

        updateStatus("running")
        emit([
            "type": "ask_question_result",
            "approved": true,
            "answer": answer,
            "toolUseId": pending ?? toolUseId ?? "",
            "time": shortLocalTime(),
        ])
        runPrintCommand([
            "用户刚刚回答了你通过 AskUserQuestion 提出的问题。",
            "请将下面内容作为该问题的用户答案，并继续之前的任务。",
            "",
            "用户回答：\(answer)",
        ].joined(separator: "\n"), isRetry: true)
    }

    func interrupt() {
        lock.lock()
        let current = process
        process = nil
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
        lock.unlock()
        current?.terminate()
        updateStatus("idle")
        emit(["type": "system", "content": "CLI 已重置", "time": shortLocalTime()])
    }

    func runOneShot(_ input: String, timeout: TimeInterval = 120) throws -> String {
        let snapshot = getConfig()
        let isolated = buildIsolatedPrintArgs(input, config: snapshot)
        let result = try Shell.run(snapshot.cliCommand, isolated.args, cwd: snapshot.workDir, input: isolated.stdin, allowExitCodes: [0])
        let text = extractOneShotText(from: result.stdout, cliType: snapshot.cliType)
        if !text.isEmpty { return text }
        let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        throw WorkspaceError.message(stderr.isEmpty ? "\(cliLabel(config: snapshot)) 未返回内容" : stderr)
    }

    private func runPrintCommand(_ input: String, isRetry: Bool) {
        let snapshot = getConfig()
        guard snapshot.runMode == "print" else {
            emit(["type": "error", "content": "当前 Swift 实现仅支持 print 模式", "time": shortLocalTime()])
            return
        }

        queue.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            if !isRetry { self.lastInput = input }
            self.hasStreamedText = false
            self.lock.unlock()
            self.updateStatus("running")

            let command = snapshot.cliCommand
            let built = self.buildPrintArgs(input, config: snapshot)
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            proc.arguments = [command] + built.args
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
                self.emit(["type": "error", "content": "\(self.cliLabel(config: snapshot)) 启动失败: \(error.localizedDescription)", "time": shortLocalTime()])
                self.updateStatus("idle")
            }
        }
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

    private func handleJSONMessage(_ msg: [String: Any], cliType: String) {
        if cliType == "codex", handleCodexJSONMessage(msg) {
            return
        }

        let type = msg["type"] as? String ?? ""
        switch type {
        case "system":
            var details: [String: Any] = [:]
            if let session = msg["session_id"] as? String, session.count > 8 {
                restoreSessionId(session)
                details["session_id"] = session
            }
            if let model = msg["model"] { details["model"] = model }
            if let subtype = msg["subtype"] { details["subtype"] = subtype }
            if let cost = msg["total_cost_usd"] ?? msg["cost_usd"] { details["costUsd"] = cost }
            if let duration = msg["duration_ms"] { details["durationMs"] = duration }
            if let turns = msg["num_turns"] { details["numTurns"] = turns }
            if let usage = msg["usage"] as? [String: Any] {
                if let value = usage["input_tokens"] { details["inputTokens"] = value }
                if let value = usage["output_tokens"] { details["outputTokens"] = value }
                if let value = usage["cache_read_input_tokens"] { details["cacheReadTokens"] = value }
                if let value = usage["cache_creation_input_tokens"] { details["cacheCreationTokens"] = value }
            }
            let content = extractText(msg["message"] ?? msg["content"]) ?? (details["subtype"] as? String == "result" ? "执行完成" : "系统消息")
            var event: [String: Any] = ["type": "system", "content": content, "time": shortLocalTime()]
            if !details.isEmpty { event["details"] = details }
            emit(event)
        case "assistant", "text", "content_block_delta":
            updateStatus("running")
            let text = extractText(msg["delta"] ?? msg["message"] ?? msg["content"] ?? msg["text"])
            if let text, !text.isEmpty {
                lock.lock()
                hasStreamedText = true
                lock.unlock()
                emit(["type": "ai_message", "content": text, "time": shortLocalTime()])
            }
        case "result", "done", "complete":
            if let sid = msg["session_id"] as? String, sid.count > 8 { restoreSessionId(sid) }
            let text = extractText(msg["content"] ?? msg["message"] ?? msg["result"])
            lock.lock()
            let shouldEmitText = !(hasStreamedText)
            hasStreamedText = false
            lock.unlock()
            if shouldEmitText, let text, !text.isEmpty {
                emit(["type": "ai_message", "content": text, "time": shortLocalTime()])
            }
            var details: [String: Any] = ["subtype": "result"]
            if let sid = msg["session_id"] { details["session_id"] = sid }
            if let cost = msg["total_cost_usd"] ?? msg["cost_usd"] { details["costUsd"] = cost }
            if let duration = msg["duration_ms"] { details["durationMs"] = duration }
            if let turns = msg["num_turns"] { details["numTurns"] = turns }
            if let model = msg["model"] { details["model"] = model }
            if let usage = msg["usage"] as? [String: Any] {
                if let value = usage["input_tokens"] { details["inputTokens"] = value }
                if let value = usage["output_tokens"] { details["outputTokens"] = value }
                if let value = usage["cache_read_input_tokens"] { details["cacheReadTokens"] = value }
                if let value = usage["cache_creation_input_tokens"] { details["cacheCreationTokens"] = value }
            }
            emit(["type": "system", "content": "执行完成", "time": shortLocalTime(), "details": details])
        case "tool_use", "tool":
            updateStatus("running")
            let name = msg["name"] as? String ?? "tool"
            let input = msg["input"].map { JSONSupport.string($0) }
            let id = msg["id"] as? String
            emit([
                "type": "tool_call",
                "content": name,
                "toolName": name,
                "status": "running",
                "details": input ?? "",
                "toolUseId": id ?? "",
                "time": shortLocalTime(),
            ])
        case "tool_result":
            let isError = (msg["is_error"] as? Bool) ?? false
            emit([
                "type": "tool_call",
                "content": isError ? "工具执行失败" : "工具执行完成",
                "toolName": msg["tool_use_id"] as? String ?? "result",
                "status": isError ? "failed" : "success",
                "details": extractText(msg["content"]) ?? "",
                "toolUseId": msg["tool_use_id"] as? String ?? "",
                "time": shortLocalTime(),
            ])
        case "error", "turn.failed":
            emit(["type": "error", "content": extractText(msg["error"] ?? msg["message"] ?? msg["content"]) ?? "\(cliLabel()) 执行失败", "time": shortLocalTime()])
        default:
            if let text = extractText(msg["content"] ?? msg["message"] ?? msg["text"]), !text.isEmpty {
                emit(["type": "ai_message", "content": text, "time": shortLocalTime()])
            }
        }
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
            var details: [String: Any] = ["subtype": "result"]
            if let usage = msg["usage"] as? [String: Any] {
                if let value = usage["input_tokens"] { details["inputTokens"] = value }
                if let value = usage["output_tokens"] { details["outputTokens"] = value }
                if let value = usage["cached_input_tokens"] { details["cacheReadTokens"] = value }
                if let value = usage["reasoning_output_tokens"] { details["reasoningOutputTokens"] = value }
            }
            if let sid = getSessionId() { details["session_id"] = sid }
            emit(["type": "system", "content": "执行完成", "time": shortLocalTime(), "details": details])
            updateStatus("idle")
            lock.lock()
            hasStreamedText = false
            lock.unlock()
            return true
        case "turn.failed", "error":
            emit(["type": "error", "content": extractText(msg["error"] ?? msg["message"] ?? msg["content"]) ?? "Codex CLI 执行失败", "time": shortLocalTime()])
            updateStatus("idle")
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
                    lock.lock()
                    hasStreamedText = true
                    lock.unlock()
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

    private func extractOneShotText(from output: String, cliType: String) -> String {
        var texts: [String] = []
        for line in output.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if let data = trimmed.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let text = oneShotText(json), !text.isEmpty {
                    texts.append(text)
                }
            } else if cliType != "codex" {
                texts.append(trimmed)
            }
        }
        return (texts.last ?? texts.joined(separator: "\n")).trimmingCharacters(in: .whitespacesAndNewlines)
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

    private func extractText(_ value: Any?) -> String? {
        guard let value else { return nil }
        if let string = value as? String { return string }
        if let array = value as? [Any] {
            let text = array.compactMap { item -> String? in
                if let string = item as? String { return string }
                if let dict = item as? [String: Any] {
                    return dict["text"] as? String ?? dict["content"] as? String
                }
                return nil
            }.joined(separator: "\n")
            return text.isEmpty ? nil : text
        }
        if let dict = value as? [String: Any] {
            if let content = dict["content"] as? [Any] {
                return extractText(content)
            }
            return dict["text"] as? String ?? dict["message"] as? String ?? dict["content"] as? String
        }
        return String(describing: value)
    }

    private func hasArg(_ args: [String], shortName: String, longName: String) -> Bool {
        args.contains { $0 == shortName || $0 == longName || $0.hasPrefix("\(longName)=") }
    }

    private func getSessionId() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return sessionId
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
        text.replacingOccurrences(of: #"\u{001B}\[[0-9;]*[a-zA-Z]|\u{001B}\].*?(?:\u{0007}|\u{001B}\\)|\r"#, with: "", options: .regularExpression)
    }
}
