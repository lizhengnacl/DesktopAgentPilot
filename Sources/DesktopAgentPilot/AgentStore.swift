import Foundation

struct CLIConfig {
    var cliType: String = "codex"
    var cliCommand: String = "codex"
    var workDir: String = FileManager.default.currentDirectoryPath
    var confirmMode: String = "key"
    var cliArgs: [String] = [
        "--dangerously-bypass-approvals-and-sandbox",
        "-m",
        "gpt-5.5",
        "-c",
        "model_reasoning_effort=\"xhigh\"",
    ]
    var runMode: String = "print"
    var cliSessionId: String?

    mutating func merge(_ input: [String: Any]) {
        if let value = input["cliType"] as? String, value == "claude" || value == "codex" {
            if value != cliType, input["cliArgs"] == nil {
                cliArgs = CLIConfig.defaultArgs(for: value)
            }
            cliType = value
        } else if let command = input["cliCommand"] as? String {
            let inferred = CLIConfig.inferType(command)
            if inferred != cliType, input["cliArgs"] == nil {
                cliArgs = CLIConfig.defaultArgs(for: inferred)
            }
            cliType = inferred
        }

        if let value = input["cliCommand"] as? String, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            cliCommand = value
        }
        if let value = input["workDir"] as? String, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            workDir = WorkspacePaths.expandHome(value)
        }
        if let value = input["confirmMode"] as? String, value == "key" || value == "auto" {
            confirmMode = value
        }
        if let value = input["cliArgs"] as? [String] {
            cliArgs = value
        } else if let value = input["cliArgs"] as? [Any] {
            cliArgs = value.compactMap { $0 as? String }
        }
        if let value = input["runMode"] as? String, value == "print" || value == "interactive" {
            runMode = value
        }
        if let value = input["cliSessionId"] as? String, value.count > 8 {
            cliSessionId = value
        }
    }

    func json(includeSessionId: Bool = false) -> [String: Any] {
        var result: [String: Any] = [
            "cliType": cliType,
            "cliCommand": cliCommand,
            "workDir": workDir,
            "confirmMode": confirmMode,
            "cliArgs": cliArgs,
            "runMode": runMode,
        ]
        if includeSessionId, let cliSessionId {
            result["cliSessionId"] = cliSessionId
        }
        return result
    }

    static func inferType(_ command: String?) -> String {
        let value = (command ?? "").lowercased()
        return value.contains("claude") ? "claude" : "codex"
    }

    static func defaultArgs(for cliType: String) -> [String] {
        if cliType == "claude" {
            return ["--dangerously-skip-permissions"]
        }
        return [
            "--dangerously-bypass-approvals-and-sandbox",
            "-m",
            "gpt-5.5",
            "-c",
            "model_reasoning_effort=\"xhigh\"",
        ]
    }
}

struct SessionMessage {
    var seq: Int
    var id: String
    var type: String
    var content: String
    var time: String
    var status: String?
    var toolName: String?
    var toolDetails: String?
    var toolUseId: String?
    var toolResult: String?
    var permission: [String: Any]?
    var details: [String: Any]?

    func clientMessage() -> [String: Any]? {
        guard let mapped = AgentStore.mapMessageType(type) else { return nil }

        var output: [String: Any] = [
            "seq": seq,
            "id": id,
            "type": mapped,
            "content": content,
            "time": time,
        ]
        if let status { output["status"] = status }
        if let toolName { output["toolName"] = toolName }
        if let toolDetails { output["toolDetails"] = toolDetails }
        if let toolUseId { output["toolUseId"] = toolUseId }
        if let toolResult { output["toolResult"] = toolResult }
        if let permission { output["permission"] = permission }
        if let details { output["details"] = details }
        if mapped == "question", type == "ask_question", let details {
            output["question"] = [
                "questions": details["questions"] as? [Any] ?? [],
                "toolUseId": details["toolUseId"] ?? toolUseId ?? "",
            ]
        }
        return output
    }
}

struct SessionRecord {
    var id: String
    var status: String
    var config: CLIConfig
    var startedAt: Int64
    var lastSeq: Int
    var messages: [SessionMessage]
}

struct HistoryTaskRecord {
    var id: String
    var sessionId: String?
    var workDir: String?
    var status: String
    var title: String
    var confirmCount: Int
    var toolCount: Int
    var duration: String?
    var startTime: Int64
    var endTime: Int64
    var createdAt: Int64
    var messages: [SessionMessage]

    func client(includeMessages: Bool) -> [String: Any] {
        var output: [String: Any] = [
            "id": id,
            "status": status,
            "title": title,
            "confirmCount": confirmCount,
            "toolCount": toolCount,
            "startTime": startTime,
            "endTime": endTime,
            "canResume": canResume,
        ]
        if let workDir { output["workDir"] = workDir }
        if let duration { output["duration"] = duration }
        if includeMessages {
            output["messages"] = messages.compactMap { $0.clientMessage() }
        }
        return output
    }

    var canResume: Bool {
        messages.contains { message in
            guard message.type == "system", let details = message.details else { return false }
            return (details["session_id"] as? String)?.count ?? 0 > 8
        }
    }
}

struct WorkDirHistoryRecord {
    var path: String
    var name: String
    var lastUsedAt: Int64
    var createdAt: Int64

    func client() -> [String: Any] {
        [
            "path": path,
            "name": name,
            "lastUsedAt": lastUsedAt,
            "createdAt": createdAt,
        ]
    }
}

final class AgentStore: @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private(set) var currentSession: SessionRecord
    private var historyTasks: [HistoryTaskRecord] = []
    private var workDirs: [String: WorkDirHistoryRecord] = [:]

    init(config: CLIConfig) {
        self.currentSession = SessionRecord(
            id: makeUUID(),
            status: "idle",
            config: config,
            startedAt: millisecondsSince1970(),
            lastSeq: 0,
            messages: []
        )
    }

    func withCurrentSession<T>(_ body: (SessionRecord) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(currentSession)
    }

    func currentSessionId() -> String {
        withCurrentSession { $0.id }
    }

    func updateCurrentConfig(_ config: CLIConfig) {
        lock.lock()
        defer { lock.unlock() }
        currentSession.config = config
    }

    func updateCurrentStatus(_ status: String) {
        lock.lock()
        defer { lock.unlock() }
        currentSession.status = status
    }

    func createSession(config: CLIConfig) -> String {
        lock.lock()
        defer { lock.unlock() }
        currentSession = SessionRecord(
            id: makeUUID(),
            status: "idle",
            config: config,
            startedAt: millisecondsSince1970(),
            lastSeq: 0,
            messages: []
        )
        return currentSession.id
    }

    func archiveCurrentSession(status: String) {
        lock.lock()
        defer { lock.unlock() }
        guard !currentSession.messages.isEmpty else { return }

        let now = millisecondsSince1970()
        let durationSeconds = max(0, (now - currentSession.startedAt) / 1000)
        let title = AgentStore.historyTitle(from: currentSession.messages)
        let task = HistoryTaskRecord(
            id: makeUUID(),
            sessionId: currentSession.id,
            workDir: currentSession.config.workDir,
            status: status,
            title: title,
            confirmCount: currentSession.messages.filter { $0.type == "confirm_request" }.count,
            toolCount: currentSession.messages.filter { $0.type == "tool_call" }.count,
            duration: AgentStore.formatDuration(seconds: durationSeconds),
            startTime: currentSession.startedAt,
            endTime: now,
            createdAt: now,
            messages: currentSession.messages
        )
        historyTasks.removeAll { $0.sessionId == currentSession.id }
        historyTasks.append(task)
    }

    func appendEvent(_ event: inout [String: Any]) {
        lock.lock()
        defer { lock.unlock() }

        guard AgentStore.persistableTypes.contains(event["type"] as? String ?? "") else { return }
        let eventType = event["type"] as? String ?? "system"
        if eventType == "system",
           let details = event["details"] as? [String: Any],
           let cliSessionId = details["session_id"] as? String,
           cliSessionId.count > 8 {
            currentSession.config.cliSessionId = cliSessionId
        }

        let isToolCall = eventType == "tool_call"
        let isToolResult = isToolCall && ["success", "failed"].contains(event["status"] as? String ?? "")
        let toolUseId = event["toolUseId"] as? String
        if isToolResult, let toolUseId,
           let index = currentSession.messages.lastIndex(where: { $0.type == "tool_call" && $0.toolUseId == toolUseId }) {
            currentSession.messages[index].status = event["status"] as? String
            currentSession.messages[index].toolResult = event["details"] as? String
            event["id"] = currentSession.messages[index].id
            event["seq"] = currentSession.messages[index].seq
            return
        }

        currentSession.lastSeq += 1
        let seq = currentSession.lastSeq
        let id = event["id"] as? String ?? makeUUID()

        var details = event["details"] as? [String: Any]
        if eventType == "ask_question" {
            details = [
                "questions": event["questions"] as? [Any] ?? [],
                "toolUseId": event["toolUseId"] ?? "",
            ]
        } else if eventType == "ask_question_result" {
            details = [
                "answered": true,
                "answer": event["answer"] ?? "",
                "toolUseId": event["toolUseId"] ?? "",
            ]
        }

        let message = SessionMessage(
            seq: seq,
            id: id,
            type: eventType,
            content: event["content"] as? String ?? "",
            time: event["time"] as? String ?? shortLocalTime(),
            status: event["status"] as? String,
            toolName: event["toolName"] as? String,
            toolDetails: isToolCall ? (event["details"] as? String ?? event["toolDetails"] as? String) : event["toolDetails"] as? String,
            toolUseId: toolUseId,
            toolResult: event["toolResult"] as? String,
            permission: event["permission"] as? [String: Any],
            details: details
        )

        currentSession.messages.append(message)
        event["id"] = id
        event["seq"] = seq
    }

    func sessionData(afterSeq: Any? = nil, beforeSeq: Any? = nil, limit: Any? = nil) -> [String: Any] {
        lock.lock()
        defer { lock.unlock() }

        let after = AgentStore.readPositiveInt(afterSeq)
        let before = AgentStore.readPositiveInt(beforeSeq)
        let maxCount = AgentStore.readPositiveInt(limit)

        let messages: [SessionMessage]
        if after > 0 {
            messages = currentSession.messages.filter { $0.seq > after }
        } else if before > 0 && maxCount > 0 {
            messages = Array(currentSession.messages.filter { $0.seq < before }.suffix(maxCount))
        } else if maxCount > 0 {
            messages = Array(currentSession.messages.suffix(maxCount))
        } else {
            messages = currentSession.messages
        }

        let firstSeq = messages.first?.seq ?? 0
        return [
            "sessionId": currentSession.id,
            "messages": messages.compactMap { $0.clientMessage() },
            "lastSeq": currentSession.lastSeq,
            "firstSeq": firstSeq,
            "hasMoreBefore": firstSeq > 0 && currentSession.messages.contains { $0.seq < firstSeq },
            "tokenUsage": tokenUsage(for: currentSession.messages),
        ]
    }

    func historyList(workDir: String) -> [[String: Any]] {
        lock.lock()
        defer { lock.unlock() }
        return historyTasks
            .filter { $0.workDir == nil || $0.workDir == workDir }
            .sorted { $0.createdAt > $1.createdAt }
            .map { $0.client(includeMessages: false) }
    }

    func historyTask(id: String, workDir: String) -> [String: Any]? {
        lock.lock()
        defer { lock.unlock() }
        return historyTasks
            .first { $0.id == id && ($0.workDir == nil || $0.workDir == workDir) }?
            .client(includeMessages: true)
    }

    func resumeHistoryTask(id: String, workDir: String, config: CLIConfig) -> (messages: [SessionMessage], lastSeq: Int, cliSessionId: String?)? {
        lock.lock()
        defer { lock.unlock() }
        guard let task = historyTasks.first(where: { $0.id == id && ($0.workDir == nil || $0.workDir == workDir) }) else {
            return nil
        }
        var restoredConfig = config
        if let taskWorkDir = task.workDir {
            restoredConfig.workDir = taskWorkDir
        }
        let cliSessionId = AgentStore.latestCliSessionId(in: task.messages)
        restoredConfig.cliSessionId = cliSessionId
        let lastSeq = task.messages.map(\.seq).max() ?? 0
        currentSession = SessionRecord(
            id: task.sessionId ?? makeUUID(),
            status: "idle",
            config: restoredConfig,
            startedAt: task.startTime,
            lastSeq: lastSeq,
            messages: task.messages
        )
        return (task.messages, lastSeq, cliSessionId)
    }

    func deleteHistoryTask(id: String, workDir: String) {
        lock.lock()
        defer { lock.unlock() }
        historyTasks.removeAll { $0.id == id && ($0.workDir == nil || $0.workDir == workDir) }
    }

    func clearHistory(workDir: String) {
        lock.lock()
        defer { lock.unlock() }
        historyTasks.removeAll { $0.workDir == nil || $0.workDir == workDir }
    }

    func importLocalData(messages: [Any], historyTasks importedTasks: [Any], workDir: String) {
        lock.lock()
        defer { lock.unlock() }

        for item in messages {
            guard let raw = item as? [String: Any] else { continue }
            currentSession.lastSeq += 1
            currentSession.messages.append(SessionMessage(
                seq: currentSession.lastSeq,
                id: raw["id"] as? String ?? makeUUID(),
                type: raw["type"] as? String ?? "system",
                content: raw["content"] as? String ?? "",
                time: raw["time"] as? String ?? shortLocalTime(),
                status: raw["status"] as? String,
                toolName: raw["toolName"] as? String,
                toolDetails: raw["toolDetails"] as? String,
                toolUseId: raw["toolUseId"] as? String,
                toolResult: raw["toolResult"] as? String,
                permission: raw["permission"] as? [String: Any],
                details: raw["details"] as? [String: Any]
            ))
        }

        for item in importedTasks {
            guard let raw = item as? [String: Any] else { continue }
            let now = millisecondsSince1970()
            let id = raw["id"] as? String ?? makeUUID()
            if historyTasks.contains(where: { $0.id == id }) { continue }
            historyTasks.append(HistoryTaskRecord(
                id: id,
                sessionId: raw["sessionId"] as? String,
                workDir: raw["workDir"] as? String ?? workDir,
                status: raw["status"] as? String ?? "completed",
                title: raw["title"] as? String ?? "会话记录",
                confirmCount: raw["confirmCount"] as? Int ?? 0,
                toolCount: raw["toolCount"] as? Int ?? 0,
                duration: raw["duration"] as? String,
                startTime: AgentStore.int64(raw["startTime"]) ?? now,
                endTime: AgentStore.int64(raw["endTime"]) ?? now,
                createdAt: AgentStore.int64(raw["createdAt"]) ?? now,
                messages: []
            ))
        }
    }

    func recordWorkDir(_ rawPath: String) {
        lock.lock()
        defer { lock.unlock() }
        let path = WorkspacePaths.resolveAbsolute(rawPath)
        guard FileManager.default.fileExists(atPath: path, isDirectory: nil) else { return }
        let now = millisecondsSince1970()
        if var existing = workDirs[path] {
            existing.lastUsedAt = now
            workDirs[path] = existing
        } else {
            workDirs[path] = WorkDirHistoryRecord(
                path: path,
                name: URL(fileURLWithPath: path).lastPathComponent,
                lastUsedAt: now,
                createdAt: now
            )
        }
    }

    func recentWorkDirs(current: String) -> [[String: Any]] {
        recordWorkDir(current)
        lock.lock()
        defer { lock.unlock() }
        return workDirs.values
            .filter { FileManager.default.fileExists(atPath: $0.path, isDirectory: nil) }
            .sorted { $0.lastUsedAt > $1.lastUsedAt }
            .map { $0.client() }
    }

    func messageBeforeBranch(id: String) -> (source: SessionRecord, target: SessionMessage)? {
        lock.lock()
        defer { lock.unlock() }
        guard let target = currentSession.messages.first(where: { $0.id == id }) else { return nil }
        return (currentSession, target)
    }

    func branchBefore(message: SessionMessage, config: CLIConfig) -> [SessionMessage] {
        lock.lock()
        defer { lock.unlock() }
        let prefix = currentSession.messages.filter { $0.seq < message.seq }
        currentSession = SessionRecord(
            id: makeUUID(),
            status: "idle",
            config: config,
            startedAt: millisecondsSince1970(),
            lastSeq: prefix.map(\.seq).max() ?? 0,
            messages: prefix
        )
        return prefix
    }

    private func tokenUsage(for messages: [SessionMessage]) -> [String: Any] {
        var inputTokens = 0
        var outputTokens = 0
        var cacheReadTokens = 0
        var cacheCreationTokens = 0
        var costUsd = 0.0

        for message in messages where message.type == "system" {
            guard let details = message.details, details["subtype"] as? String == "result" else { continue }
            inputTokens += AgentStore.int(details["inputTokens"]) ?? 0
            outputTokens += AgentStore.int(details["outputTokens"]) ?? 0
            cacheReadTokens += AgentStore.int(details["cacheReadTokens"]) ?? 0
            cacheCreationTokens += AgentStore.int(details["cacheCreationTokens"]) ?? 0
            costUsd += AgentStore.double(details["costUsd"]) ?? 0
        }

        return [
            "inputTokens": inputTokens,
            "outputTokens": outputTokens,
            "cacheReadTokens": cacheReadTokens,
            "cacheCreationTokens": cacheCreationTokens,
            "costUsd": costUsd,
        ]
    }

    static let persistableTypes: Set<String> = [
        "user_message",
        "ai_message",
        "thinking_message",
        "tool_call",
        "confirm_request",
        "confirm_result",
        "confirm_mode_changed",
        "ask_question",
        "ask_question_result",
        "system",
        "error",
        "status",
    ]

    static func mapMessageType(_ eventType: String) -> String? {
        switch eventType {
        case "user_message": return "user"
        case "ai_message": return "ai"
        case "thinking_message": return "thinking"
        case "tool_call": return "tool"
        case "confirm_request", "confirm_result": return "confirm"
        case "ask_question", "ask_question_result": return "question"
        case "system": return "system"
        case "error": return "error"
        case "status", "confirm_mode_changed": return nil
        default: return eventType
        }
    }

    private static func readPositiveInt(_ value: Any?) -> Int {
        guard let value else { return 0 }
        if let int = value as? Int, int > 0 { return int }
        if let int64 = value as? Int64, int64 > 0 { return Int(int64) }
        if let string = value as? String, let int = Int(string), int > 0 { return int }
        if let number = value as? NSNumber, number.intValue > 0 { return number.intValue }
        return 0
    }

    private static func int(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value) }
        return nil
    }

    private static func int64(_ value: Any?) -> Int64? {
        if let value = value as? Int64 { return value }
        if let value = value as? Int { return Int64(value) }
        if let value = value as? NSNumber { return value.int64Value }
        if let value = value as? String { return Int64(value) }
        return nil
    }

    private static func double(_ value: Any?) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? String { return Double(value) }
        return nil
    }

    private static func historyTitle(from messages: [SessionMessage]) -> String {
        let content = messages.first { $0.type == "user_message" || $0.type == "user" }?.content ?? ""
        let normalized = content
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.hasPrefix("<") }
            .joined(separator: " ")
        guard !normalized.isEmpty else { return "会话记录" }
        if normalized.count <= 48 { return normalized }
        let index = normalized.index(normalized.startIndex, offsetBy: 48)
        return String(normalized[..<index]).trimmingCharacters(in: .whitespacesAndNewlines) + "..."
    }

    private static func formatDuration(seconds: Int64) -> String {
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        return "\(seconds / 3600)h"
    }

    private static func latestCliSessionId(in messages: [SessionMessage]) -> String? {
        for message in messages.reversed() where message.type == "system" {
            if let value = message.details?["session_id"] as? String, value.count > 8 {
                return value
            }
        }
        return nil
    }
}
