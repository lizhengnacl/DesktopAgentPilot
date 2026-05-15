import Darwin
import Foundation

struct PortOccupant: Hashable {
    let pid: Int32
    let command: String
}

enum PortOccupancyError: LocalizedError {
    case lsofFailed(String)
    case invalidProcessID(String)
    case terminateFailed(pid: Int32, reason: String)

    var errorDescription: String? {
        switch self {
        case .lsofFailed(let detail):
            return detail.isEmpty ? "无法查询端口占用进程" : "无法查询端口占用进程: \(detail)"
        case .invalidProcessID(let value):
            return "端口占用进程 ID 无效: \(value)"
        case .terminateFailed(let pid, let reason):
            return "无法关闭进程 \(pid): \(reason)"
        }
    }
}

final class PortOccupancyManager {
    func listeningProcesses(on port: UInt16) throws -> [PortOccupant] {
        let result = try runLsof(arguments: [
            "-nP",
            "-iTCP:\(port)",
            "-sTCP:LISTEN",
            "-F",
            "pc",
        ])

        if result.status == 1 {
            return []
        }

        guard result.status == 0 else {
            throw PortOccupancyError.lsofFailed(result.error.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        return try parseLsofFieldOutput(result.output)
    }

    func terminate(_ processes: [PortOccupant]) throws {
        let uniqueProcesses = Array(Set(processes)).sorted { $0.pid < $1.pid }
        for process in uniqueProcesses {
            if kill(process.pid, SIGTERM) == -1 {
                let code = errno
                if code == ESRCH {
                    continue
                }
                throw PortOccupancyError.terminateFailed(pid: process.pid, reason: String(cString: strerror(code)))
            }
        }
    }

    private func parseLsofFieldOutput(_ output: String) throws -> [PortOccupant] {
        var processes: [Int32: PortOccupant] = [:]
        var currentPID: Int32?
        var currentCommand = ""

        func flushCurrentProcess() {
            guard let pid = currentPID else { return }
            let command = currentCommand.isEmpty ? "未知进程" : currentCommand
            processes[pid] = PortOccupant(pid: pid, command: command)
        }

        for rawLine in output.split(whereSeparator: \.isNewline) {
            guard let key = rawLine.first else { continue }
            let value = String(rawLine.dropFirst())

            switch key {
            case "p":
                flushCurrentProcess()
                guard let pid = Int32(value) else {
                    throw PortOccupancyError.invalidProcessID(value)
                }
                currentPID = pid
                currentCommand = ""
            case "c":
                currentCommand = value
            default:
                continue
            }
        }

        flushCurrentProcess()
        return processes.values.sorted { $0.pid < $1.pid }
    }

    private func runLsof(arguments: [String]) throws -> (status: Int32, output: String, error: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = arguments

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
        } catch {
            throw PortOccupancyError.lsofFailed(error.localizedDescription)
        }

        process.waitUntilExit()

        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        return (
            status: process.terminationStatus,
            output: String(data: outputData, encoding: .utf8) ?? "",
            error: String(data: errorData, encoding: .utf8) ?? ""
        )
    }
}
