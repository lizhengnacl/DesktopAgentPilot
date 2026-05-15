import Foundation

enum WorkspaceError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let text): return text
        }
    }
}

enum WorkspacePaths {
    static func expandHome(_ path: String) -> String {
        if path == "~" { return FileManager.default.homeDirectoryForCurrentUser.path }
        if path.hasPrefix("~/") {
            return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(String(path.dropFirst(2))).path
        }
        return path
    }

    static func resolveAbsolute(_ path: String) -> String {
        URL(fileURLWithPath: expandHome(path)).standardizedFileURL.path
    }

    static func normalizeWorkspacePath(_ raw: Any?) -> String {
        guard let raw = raw as? String else { return "" }
        return raw
            .replacingOccurrences(of: "\\", with: "/")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"^/+"#, with: "", options: .regularExpression)
            .split(separator: "/")
            .filter { !$0.isEmpty && $0 != "." }
            .joined(separator: "/")
    }

    static func relativePath(root: String, path: String) -> String {
        let rootURL = URL(fileURLWithPath: root).standardizedFileURL
        let pathURL = URL(fileURLWithPath: path).standardizedFileURL
        let rootComponents = rootURL.pathComponents
        let pathComponents = pathURL.pathComponents
        guard pathComponents.starts(with: rootComponents) else { return "" }
        let suffix = pathComponents.dropFirst(rootComponents.count)
        return suffix.joined(separator: "/")
    }

    static func resolveWorkspacePath(root rawRoot: String, rawPath: Any?, mustExist: Bool = true) throws -> (root: String, target: String, relativePath: String) {
        let root = resolveAbsolute(rawRoot)
        let rootURL = URL(fileURLWithPath: root).resolvingSymlinksInPath().standardizedFileURL
        let relative = normalizeWorkspacePath(rawPath)
        let target = URL(fileURLWithPath: root).appendingPathComponent(relative).standardizedFileURL.path
        let targetURL = URL(fileURLWithPath: target).standardizedFileURL

        if targetURL.path != URL(fileURLWithPath: root).standardizedFileURL.path,
           !targetURL.path.hasPrefix(URL(fileURLWithPath: root).standardizedFileURL.path + "/") {
            throw WorkspaceError.message("路径不在当前工作目录内")
        }

        if mustExist {
            guard FileManager.default.fileExists(atPath: targetURL.path) else {
                throw WorkspaceError.message("路径不存在")
            }
            let realTarget = targetURL.resolvingSymlinksInPath()
            if realTarget.path != rootURL.path, !realTarget.path.hasPrefix(rootURL.path + "/") {
                throw WorkspaceError.message("路径不在当前工作目录内")
            }
        }

        return (root, targetURL.path, relative)
    }
}

struct ProcessResult {
    var stdout: String
    var stderr: String
    var status: Int32
}

enum Shell {
    static func run(_ command: String, _ args: [String], cwd: String, input: String? = nil, allowExitCodes: Set<Int32> = [0]) throws -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [command] + args
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        var env = ProcessInfo.processInfo.environment
        env["FORCE_COLOR"] = "0"
        env["NO_COLOR"] = "1"
        process.environment = env

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        if input != nil {
            process.standardInput = Pipe()
        }

        do {
            try process.run()
        } catch {
            throw WorkspaceError.message("\(command) 启动失败: \(error.localizedDescription)")
        }

        if let input, let stdin = process.standardInput as? Pipe {
            stdin.fileHandleForWriting.write(Data(input.utf8))
            try? stdin.fileHandleForWriting.close()
        }

        process.waitUntilExit()
        let stdoutData = stdout.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderr.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: stdoutData, encoding: .utf8) ?? ""
        let errorText = String(data: stderrData, encoding: .utf8) ?? ""
        let result = ProcessResult(stdout: output, stderr: errorText, status: process.terminationStatus)

        guard allowExitCodes.contains(process.terminationStatus) else {
            let detail = errorText.trimmingCharacters(in: .whitespacesAndNewlines)
            throw WorkspaceError.message(detail.isEmpty ? "\(command) 退出码 \(process.terminationStatus)" : detail)
        }
        return result
    }
}

final class SkillDiscovery: @unchecked Sendable {
    func discover(workDir: String) -> [[String: Any]] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let roots: [(String, Int)] = [
            ("\(home)/.agents/skills", 3),
            ("\(home)/.codex/skills", 4),
            ("\(home)/.claude/skills", 4),
            ("\(home)/.codex/plugins/cache", 8),
            ("\(workDir)/.agents/skills", 4),
            ("\(workDir)/.codex/skills", 4),
            ("\(workDir)/.claude/skills", 4),
        ]

        var byName: [String: [String: Any]] = [:]
        for (root, depth) in roots {
            for file in collectSkillFiles(root: root, maxDepth: depth) {
                let meta = readSkillMeta(file)
                let fallback = URL(fileURLWithPath: file).deletingLastPathComponent().lastPathComponent
                let name = (meta["name"] ?? fallback).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty, byName[name] == nil else { continue }
                byName[name] = [
                    "name": name,
                    "command": "/\(name)",
                    "description": meta["description"] ?? "Skill",
                    "path": file,
                    "source": source(for: file),
                ]
            }
        }

        return byName.values.sorted { lhs, rhs in
            (lhs["name"] as? String ?? "") < (rhs["name"] as? String ?? "")
        }
    }

    private func collectSkillFiles(root: String, maxDepth: Int) -> [String] {
        var result: [String] = []
        let rootPath = WorkspacePaths.expandHome(root)
        walk(rootPath, depth: 0, maxDepth: maxDepth, result: &result)
        return result
    }

    private func walk(_ dir: String, depth: Int, maxDepth: Int, result: inout [String]) {
        guard depth <= maxDepth else { return }
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return }
        for entry in entries {
            let path = URL(fileURLWithPath: dir).appendingPathComponent(entry).path
            var isDir = ObjCBool(false)
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else { continue }
            if !isDir.boolValue, entry == "SKILL.md" {
                result.append(path)
            } else if isDir.boolValue {
                walk(path, depth: depth + 1, maxDepth: maxDepth, result: &result)
            }
        }
    }

    private func readSkillMeta(_ path: String) -> [String: String] {
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return [:] }
        guard content.hasPrefix("---\n"), let end = content.dropFirst(4).range(of: "\n---") else { return [:] }
        let frontMatter = content[content.index(content.startIndex, offsetBy: 4)..<end.lowerBound]
        var meta: [String: String] = [:]
        for line in frontMatter.split(separator: "\n") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespacesAndNewlines)
            var value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
            if (value.hasPrefix("\"") && value.hasSuffix("\"")) || (value.hasPrefix("'") && value.hasSuffix("'")) {
                value = String(value.dropFirst().dropLast())
            }
            if key == "name" || key == "description" {
                meta[key] = value
            }
        }
        return meta
    }

    private func source(for path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path.hasPrefix("\(home)/.agents/skills") { return "Agents" }
        if path.hasPrefix("\(home)/.codex/skills") { return "Codex" }
        if path.hasPrefix("\(home)/.claude/skills") { return "Claude" }
        if path.contains("/.codex/plugins/cache/") { return "Plugin" }
        return "Workspace"
    }
}

final class WorkspaceService: @unchecked Sendable {
    private let skipNames: Set<String> = [
        ".git", ".DS_Store", ".cache", ".pnpm-store", ".venv", "node_modules",
        "dist", "build", "coverage", ".next", ".turbo", ".vite",
    ]
    private let maxFileBytes: UInt64 = 512 * 1024
    private let maxDiffBytes = 1024 * 1024
    private let maxCommitContextBytes = 160 * 1024
    private let imageMimeByExtension: [String: String] = [
        ".avif": "image/avif",
        ".bmp": "image/bmp",
        ".gif": "image/gif",
        ".ico": "image/x-icon",
        ".jpeg": "image/jpeg",
        ".jpg": "image/jpeg",
        ".png": "image/png",
        ".svg": "image/svg+xml",
        ".webp": "image/webp",
    ]

    var workDirProvider: () -> String

    init(workDirProvider: @escaping () -> String) {
        self.workDirProvider = workDirProvider
    }

    func listSystemDir(_ rawDir: Any?, includeFiles: Bool) throws -> [String: Any] {
        let base = (rawDir as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "~"
        let resolved = WorkspacePaths.resolveAbsolute(base)
        let entries = try FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: resolved), includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey], options: [])

        let dirs = entries.compactMap { url -> [String: Any]? in
            guard !url.lastPathComponent.hasPrefix("."),
                  (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return nil }
            return ["name": url.lastPathComponent, "path": url.path]
        }.sorted { ($0["name"] as? String ?? "") < ($1["name"] as? String ?? "") }

        let files: [[String: Any]]
        if includeFiles {
            files = entries.compactMap { url -> [String: Any]? in
                guard !url.lastPathComponent.hasPrefix("."),
                      (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { return nil }
                return [
                    "name": url.lastPathComponent,
                    "path": url.path,
                    "ext": url.pathExtension.isEmpty ? "" : ".\(url.pathExtension.lowercased())",
                ]
            }.sorted { ($0["name"] as? String ?? "") < ($1["name"] as? String ?? "") }
        } else {
            files = []
        }

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let quickAccess = [
            ("主目录", home, "home"),
            ("桌面", "\(home)/Desktop", "desktop"),
            ("文档", "\(home)/Documents", "documents"),
            ("下载", "\(home)/Downloads", "downloads"),
        ].compactMap { item -> [String: Any]? in
            var isDir = ObjCBool(false)
            guard FileManager.default.fileExists(atPath: item.1, isDirectory: &isDir), isDir.boolValue else { return nil }
            return ["name": item.0, "path": item.1, "icon": item.2]
        }

        let parent = URL(fileURLWithPath: resolved).deletingLastPathComponent().path
        return [
            "dir": resolved,
            "parent": parent,
            "dirs": dirs,
            "files": files,
            "quickAccess": quickAccess,
            "isRoot": parent == resolved,
        ]
    }

    func listWorkspaceDir(_ rawPath: Any?) throws -> [String: Any] {
        let resolved = try WorkspacePaths.resolveWorkspacePath(root: workDirProvider(), rawPath: rawPath)
        var isDir = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: resolved.target, isDirectory: &isDir), isDir.boolValue else {
            throw WorkspaceError.message("目标不是目录")
        }

        let entryURLs = try FileManager.default.contentsOfDirectory(
            at: URL(fileURLWithPath: resolved.target),
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
            options: []
        )
        let realRoot = URL(fileURLWithPath: resolved.root).resolvingSymlinksInPath().path
        var dirs: [[String: Any]] = []
        var files: [[String: Any]] = []

        for url in entryURLs {
            if skipNames.contains(url.lastPathComponent) { continue }
            let real = url.resolvingSymlinksInPath().path
            guard real == realRoot || real.hasPrefix(realRoot + "/") else { continue }
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey, .contentModificationDateKey])
            let mtime = Int64(((values?.contentModificationDate ?? Date()).timeIntervalSince1970 * 1000).rounded())
            if values?.isDirectory == true {
                dirs.append([
                    "name": url.lastPathComponent,
                    "path": WorkspacePaths.relativePath(root: resolved.root, path: url.path),
                    "mtime": mtime,
                ])
            } else if values?.isRegularFile == true {
                files.append([
                    "name": url.lastPathComponent,
                    "path": WorkspacePaths.relativePath(root: resolved.root, path: url.path),
                    "ext": url.pathExtension.isEmpty ? "" : ".\(url.pathExtension.lowercased())",
                    "size": values?.fileSize ?? 0,
                    "mtime": mtime,
                ])
            }
        }

        dirs.sort { ($0["name"] as? String ?? "") < ($1["name"] as? String ?? "") }
        files.sort { ($0["name"] as? String ?? "") < ($1["name"] as? String ?? "") }

        let currentPath = WorkspacePaths.relativePath(root: resolved.root, path: resolved.target)
        let parent = resolved.target == resolved.root
            ? ""
            : WorkspacePaths.relativePath(root: resolved.root, path: URL(fileURLWithPath: resolved.target).deletingLastPathComponent().path)
        return [
            "workDir": resolved.root,
            "path": currentPath,
            "parent": parent,
            "isRoot": resolved.target == resolved.root,
            "dirs": dirs,
            "files": files,
        ]
    }

    func readWorkspaceFile(_ rawPath: Any?) throws -> [String: Any] {
        let resolved = try WorkspacePaths.resolveWorkspacePath(root: workDirProvider(), rawPath: rawPath)
        let url = URL(fileURLWithPath: resolved.target)
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey])
        guard values.isRegularFile == true else {
            throw WorkspaceError.message("目标不是文件")
        }

        let size = UInt64(values.fileSize ?? 0)
        let mimeType = imageMimeByExtension[url.pathExtension.isEmpty ? "" : ".\(url.pathExtension.lowercased())"]
        let isImage = mimeType != nil
        let mtime = Int64(((values.contentModificationDate ?? Date()).timeIntervalSince1970 * 1000).rounded())

        var result: [String: Any] = [
            "workDir": resolved.root,
            "path": WorkspacePaths.relativePath(root: resolved.root, path: resolved.target),
            "name": url.lastPathComponent,
            "size": size,
            "mtime": mtime,
            "content": "",
            "tooLarge": size > maxFileBytes,
            "isBinary": false,
            "isImage": isImage,
        ]
        if let mimeType { result["mimeType"] = mimeType }

        guard size <= maxFileBytes else { return result }
        let data = try Data(contentsOf: url)
        let isBinary = !isImage && isLikelyBinary(data)
        result["isBinary"] = isBinary
        if isImage, let mimeType {
            result["dataUrl"] = "data:\(mimeType);base64,\(data.base64EncodedString())"
        } else if !isBinary {
            result["content"] = String(data: data, encoding: .utf8) ?? ""
        }
        return result
    }

    func getWorkspaceChanges(_ rawPath: Any?) throws -> [String: Any] {
        _ = try WorkspacePaths.resolveWorkspacePath(root: workDirProvider(), rawPath: "", mustExist: true)
        guard isGitRepo() else {
            return [
                "workDir": WorkspacePaths.resolveAbsolute(workDirProvider()),
                "isGitRepo": false,
                "branch": "",
                "files": [],
                "diff": "",
                "truncated": false,
            ]
        }

        let selectedPath = WorkspacePaths.normalizeWorkspacePath(rawPath)
        if !selectedPath.isEmpty {
            _ = try WorkspacePaths.resolveWorkspacePath(root: workDirProvider(), rawPath: selectedPath, mustExist: false)
        }

        let branch = try git(["rev-parse", "--abbrev-ref", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
        let statusOutput = try git(["status", "--porcelain=v1", "-z", "--untracked-files=all", "--", "."])
        let files = parseGitStatus(statusOutput, nulTerminated: true)
        let diffTarget = selectedPath.isEmpty ? "." : selectedPath
        let staged = try git(["diff", "--cached", "--", diffTarget])
        let unstaged = try git(["diff", "--", diffTarget])
        var parts: [String] = []
        if !staged.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append("--- 已暂存变更 ---\n\(staged)")
        }
        if !unstaged.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append("--- 未暂存变更 ---\n\(unstaged)")
        }

        if !selectedPath.isEmpty, parts.isEmpty,
           let selected = files.first(where: { $0["path"] as? String == selectedPath }),
           selected["status"] as? String == "??" {
            let resolved = try WorkspacePaths.resolveWorkspacePath(root: workDirProvider(), rawPath: selectedPath)
            let attrs = try FileManager.default.attributesOfItem(atPath: resolved.target)
            let size = attrs[.size] as? UInt64 ?? 0
            if size <= maxFileBytes {
                let diff = try git(["diff", "--no-index", "--", "/dev/null", resolved.target], allowExitCodes: [0, 1])
                if !diff.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    parts.append(diff)
                }
            }
        }

        let diff = truncate(parts.joined(separator: "\n"), maxBytes: maxDiffBytes)
        var result: [String: Any] = [
            "workDir": WorkspacePaths.resolveAbsolute(workDirProvider()),
            "isGitRepo": true,
            "branch": branch,
            "files": files,
            "diff": diff.text,
            "truncated": diff.truncated,
        ]
        if !selectedPath.isEmpty { result["diffPath"] = selectedPath }
        return result
    }

    func trackWorkspaceFile(_ rawPath: Any?) throws -> [String: Any] {
        try ensureGitRepo()
        let selectedPath = WorkspacePaths.normalizeWorkspacePath(rawPath)
        guard !selectedPath.isEmpty else { throw WorkspaceError.message("请选择要追踪的文件") }
        let resolved = try WorkspacePaths.resolveWorkspacePath(root: workDirProvider(), rawPath: selectedPath)
        let values = try URL(fileURLWithPath: resolved.target).resourceValues(forKeys: [.isRegularFileKey])
        guard values.isRegularFile == true else { throw WorkspaceError.message("只能追踪文件") }
        let status = parseGitStatus(try git(["status", "--porcelain=v1", "-z", "--untracked-files=all", "--", selectedPath]), nulTerminated: true)
        guard status.contains(where: { $0["path"] as? String == selectedPath && $0["status"] as? String == "??" }) else {
            throw WorkspaceError.message("文件不是未跟踪状态")
        }
        _ = try git(["add", "--", selectedPath])
        return [
            "workDir": WorkspacePaths.resolveAbsolute(workDirProvider()),
            "path": selectedPath,
            "tracked": true,
        ]
    }

    func stageWorkspacePath(_ rawPath: Any?) throws -> [String: Any] {
        try ensureGitRepo()
        let selectedPath = WorkspacePaths.normalizeWorkspacePath(rawPath)
        if selectedPath.isEmpty {
            _ = try git(["add", "--all", "--", "."])
            return ["workDir": WorkspacePaths.resolveAbsolute(workDirProvider()), "staged": true]
        }
        _ = try WorkspacePaths.resolveWorkspacePath(root: workDirProvider(), rawPath: selectedPath, mustExist: false)
        let status = parseGitStatus(try git(["status", "--porcelain=v1", "-z", "--untracked-files=all", "--", selectedPath]), nulTerminated: true)
        guard !status.isEmpty else { throw WorkspaceError.message("文件没有可暂存的变更") }
        _ = try git(["add", "--", selectedPath])
        return ["workDir": WorkspacePaths.resolveAbsolute(workDirProvider()), "path": selectedPath, "staged": true]
    }

    func unstageWorkspacePath(_ rawPath: Any?) throws -> [String: Any] {
        try ensureGitRepo()
        let selectedPath = WorkspacePaths.normalizeWorkspacePath(rawPath)
        if selectedPath.isEmpty {
            _ = try git(["restore", "--staged", "--", "."])
            return ["workDir": WorkspacePaths.resolveAbsolute(workDirProvider()), "unstaged": true]
        }
        _ = try WorkspacePaths.resolveWorkspacePath(root: workDirProvider(), rawPath: selectedPath, mustExist: false)
        let status = parseGitStatus(try git(["status", "--porcelain=v1", "-z", "--untracked-files=all", "--", selectedPath]), nulTerminated: true)
        guard status.contains(where: { ($0["indexStatus"] as? String ?? " ") != " " && ($0["indexStatus"] as? String ?? "?") != "?" }) else {
            throw WorkspaceError.message("文件没有已暂存的变更")
        }
        _ = try git(["restore", "--staged", "--", selectedPath])
        return ["workDir": WorkspacePaths.resolveAbsolute(workDirProvider()), "path": selectedPath, "unstaged": true]
    }

    func commitWorkspaceChanges(_ rawMessage: Any?) throws -> [String: Any] {
        try ensureGitRepo()
        let message = normalizeCommitMessage(rawMessage)
        guard !message.isEmpty else { throw WorkspaceError.message("提交信息不能为空") }
        let status = try git(["status", "--porcelain=v1", "--untracked-files=all", "--", "."])
        guard !status.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw WorkspaceError.message("没有可提交的代码变更")
        }
        let staged = try git(["diff", "--cached", "--name-only"])
        guard !staged.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw WorkspaceError.message("没有已暂存的代码变更，请先暂存要提交的文件")
        }
        _ = try git(["commit", "-m", message])
        let commitHash = try git(["rev-parse", "--short", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
        let branch = try git(["rev-parse", "--abbrev-ref", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
        return [
            "workDir": WorkspacePaths.resolveAbsolute(workDirProvider()),
            "branch": branch,
            "commitHash": commitHash,
            "message": message,
        ]
    }

    func buildCommitMessagePrompt() throws -> String {
        try ensureGitRepo()
        let statusOutput = try git(["status", "--porcelain=v1", "-z", "--untracked-files=all", "--", "."])
        let files = parseGitStatus(statusOutput, nulTerminated: true)
        guard !files.isEmpty else { throw WorkspaceError.message("没有可提交的代码变更") }
        let stagedFiles = try git(["diff", "--cached", "--name-only"])
        guard !stagedFiles.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw WorkspaceError.message("没有已暂存的代码变更，请先暂存要提交的文件")
        }

        let recentCommits = (try? git(["log", "--oneline", "-8"], allowExitCodes: [0, 128]))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let stagedStat = try git(["diff", "--cached", "--stat"]).trimmingCharacters(in: .whitespacesAndNewlines)
        let stagedDiff = try git(["diff", "--cached"])
        let branch = try git(["rev-parse", "--abbrev-ref", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
        let statusText = files.map { "\($0["status"] as? String ?? "") \($0["path"] as? String ?? "")" }.joined(separator: "\n")
        let context = truncate([
            "当前分支：\(branch)",
            recentCommits.isEmpty ? "" : "最近提交：\n\(recentCommits)",
            "状态：\n\(statusText)",
            stagedStat.isEmpty ? "" : "已暂存统计：\n\(stagedStat)",
            stagedDiff.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : "已暂存 diff：\n\(stagedDiff)",
        ].filter { !$0.isEmpty }.joined(separator: "\n\n"), maxBytes: maxCommitContextBytes)

        return [
            "请基于下面的 Git 变更生成一条提交信息。",
            "要求：",
            "- 只输出 commit message，不要解释，不要 Markdown 代码块。",
            "- 使用 Conventional Commits：<type>(<scope>): <subject> 或 <type>: <subject>。",
            "- type 优先使用 feat/fix/docs/refactor/test/chore/style/build/ci/perf。",
            "- subject 简短、具体、动词开头，使用英文小写；必要时可以补充简短 body。",
            "- 不要提到 AI、不要提到你无法验证的内容。",
            "",
            context.truncated ? "注意：变更上下文已截断。" : "",
            "已暂存 Git 变更上下文：",
            context.text,
        ].filter { !$0.isEmpty }.joined(separator: "\n")
    }

    func normalizeAICommitMessage(_ raw: String) -> String {
        var message = normalizeCommitMessage(raw)
        if message.hasPrefix("```") {
            message = message.replacingOccurrences(of: #"^```(?:\w+)?\n?"#, with: "", options: .regularExpression)
            message = message.replacingOccurrences(of: #"\n?```$"#, with: "", options: .regularExpression)
        }
        message = message.replacingOccurrences(of: #"(?i)^commit message\s*:\s*"#, with: "", options: .regularExpression)
        message = message.trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”‘’").union(.whitespacesAndNewlines))
        return message
            .components(separatedBy: .newlines)
            .map { $0.replacingOccurrences(of: #"^\s*[-*]\s+"#, with: "", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines) }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func normalizeCommitMessage(_ raw: Any?) -> String {
        guard let raw = raw as? String else { return "" }
        return raw.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\0", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func isLikelyBinary(_ data: Data) -> Bool {
        data.prefix(4096).contains(0)
    }

    private func isGitRepo() -> Bool {
        (try? git(["rev-parse", "--is-inside-work-tree"])) != nil
    }

    private func ensureGitRepo() throws {
        _ = try WorkspacePaths.resolveWorkspacePath(root: workDirProvider(), rawPath: "", mustExist: true)
        guard isGitRepo() else { throw WorkspaceError.message("当前工作目录不是 Git 仓库") }
    }

    private func git(_ args: [String], allowExitCodes: Set<Int32> = [0]) throws -> String {
        try Shell.run("git", args, cwd: WorkspacePaths.resolveAbsolute(workDirProvider()), allowExitCodes: allowExitCodes).stdout
    }

    private func parseGitStatus(_ output: String, nulTerminated: Bool) -> [[String: Any]] {
        let records = nulTerminated ? output.split(separator: "\0", omittingEmptySubsequences: true).map(String.init) : output.components(separatedBy: .newlines)
        var files: [[String: Any]] = []
        var index = 0
        while index < records.count {
            let line = records[index]
            if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                index += 1
                continue
            }
            let chars = Array(line)
            let indexStatus = chars.count > 0 ? String(chars[0]) : " "
            let worktreeStatus = chars.count > 1 ? String(chars[1]) : " "
            let fileStart = line.index(line.startIndex, offsetBy: min(3, line.count))
            let rawPath = String(line[fileStart...])
            let filePath = rawPath.contains(" -> ") ? rawPath.components(separatedBy: " -> ").last ?? rawPath : rawPath
            files.append([
                "path": filePath,
                "name": URL(fileURLWithPath: filePath).lastPathComponent,
                "status": "\(indexStatus)\(worktreeStatus)",
                "indexStatus": indexStatus,
                "worktreeStatus": worktreeStatus,
                "label": describeGitStatus(indexStatus, worktreeStatus),
            ])
            if nulTerminated, ["R", "C"].contains(indexStatus) || ["R", "C"].contains(worktreeStatus) {
                index += 1
            }
            index += 1
        }
        return files
    }

    private func describeGitStatus(_ indexStatus: String, _ worktreeStatus: String) -> String {
        let pair = indexStatus + worktreeStatus
        if pair == "??" { return "未跟踪" }
        if pair == "!!" { return "已忽略" }
        if indexStatus == "A" || worktreeStatus == "A" { return "新增" }
        if indexStatus == "D" || worktreeStatus == "D" { return "删除" }
        if indexStatus == "R" || worktreeStatus == "R" { return "重命名" }
        if indexStatus == "C" || worktreeStatus == "C" { return "复制" }
        if indexStatus == "M" || worktreeStatus == "M" { return "修改" }
        if indexStatus == "U" || worktreeStatus == "U" { return "冲突" }
        return "变更"
    }

    private func truncate(_ text: String, maxBytes: Int) -> (text: String, truncated: Bool) {
        let data = Data(text.utf8)
        guard data.count > maxBytes else { return (text, false) }
        let prefix = data.prefix(maxBytes)
        let truncatedText = String(data: prefix, encoding: .utf8) ?? String(decoding: prefix, as: UTF8.self)
        return (truncatedText + "\n\n... diff 内容过长，已截断 ...", true)
    }
}
