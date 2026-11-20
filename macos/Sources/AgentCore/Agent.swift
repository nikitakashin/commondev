import Foundation

public enum AgentEvent {
    case message(String)
    case toolStarted(id: String, description: String)
    case toolFinished(id: String, result: String)
}

public enum ApprovalRequest: Sendable {
    case command(command: String, cwd: String)
    case edit(path: String, diff: String)
}

public enum ToolAction {
    case command(String)
    case read(path: String)
    case replace(path: String, old: String, new: String)
}

public struct ToolCall {
    public let id: String
    public let action: ToolAction

    public init(id: String, action: ToolAction) {
        self.id = id
        self.action = action
    }
}

public struct ToolResult {
    public let id: String
    public let output: String
    public let succeeded: Bool
    public let exitCode: Int32?
}

public enum ProviderResponse {
    case toolCall(ToolCall)
    case complete(message: String, success: Bool)
}

public protocol AgentProvider {
    func next(task: String, results: [ToolResult]) throws -> ProviderResponse
}

public struct AgentRunResult {
    public let success: Bool
}

public struct Agent {
    private let workspace: URL
    private let provider: any AgentProvider
    private let onEvent: (AgentEvent) -> Void
    private let approve: (ApprovalRequest) -> Bool

    public init(
        workspace: URL,
        provider: any AgentProvider,
        onEvent: @escaping (AgentEvent) -> Void,
        approve: @escaping (ApprovalRequest) -> Bool
    ) {
        self.workspace = workspace.standardizedFileURL.resolvingSymlinksInPath()
        self.provider = provider
        self.onEvent = onEvent
        self.approve = approve
    }

    public func run(task: String) throws -> AgentRunResult {
        var results: [ToolResult] = []
        var usedIDs = Set<String>()
        while true {
            switch try provider.next(task: task, results: results) {
            case .complete(let message, let success):
                onEvent(.message(message))
                return AgentRunResult(success: success)
            case .toolCall(let call):
                guard usedIDs.insert(call.id).inserted else {
                    throw AgentError.duplicateCall(call.id)
                }
                onEvent(.toolStarted(id: call.id, description: describe(call.action)))
                let result: ToolResult
                do {
                    result = try execute(call)
                } catch {
                    result = ToolResult(id: call.id, output: error.localizedDescription, succeeded: false, exitCode: nil)
                }
                results.append(result)
                onEvent(.toolFinished(id: call.id, result: result.output))
            }
        }
    }

    private func describe(_ action: ToolAction) -> String {
        switch action {
        case .command(let command): return "Команда: \(command)"
        case .read(let path): return "Чтение: \(path)"
        case .replace(let path, _, _): return "Правка: \(path)"
        }
    }

    private func fileURL(_ path: String) throws -> URL {
        guard !path.hasPrefix("/") else { throw AgentError.outsideWorkspace }
        let resolved = workspace.appendingPathComponent(path).standardizedFileURL.resolvingSymlinksInPath()
        guard resolved.path.hasPrefix(workspace.path + "/") else { throw AgentError.outsideWorkspace }
        return resolved
    }

    private func execute(_ call: ToolCall) throws -> ToolResult {
        switch call.action {
        case .read(let path):
            let contents = try String(contentsOf: fileURL(path), encoding: .utf8)
            return ToolResult(id: call.id, output: contents, succeeded: true, exitCode: nil)
        case .replace(let path, let old, let new):
            guard !old.isEmpty else { throw AgentError.invalidReplacement }
            let url = try fileURL(path)
            let original = try String(contentsOf: url, encoding: .utf8)
            let parts = original.components(separatedBy: old)
            guard parts.count == 2 else { throw AgentError.invalidReplacement }
            let changed = parts[0] + new + parts[1]
            let diff = "--- a/\(path)\n+++ b/\(path)\n-\(old)\n+\(new)"
            guard approve(.edit(path: path, diff: diff)) else {
                return ToolResult(id: call.id, output: "Правка отклонена пользователем.", succeeded: false, exitCode: nil)
            }
            guard try String(contentsOf: fileURL(path), encoding: .utf8) == original else {
                throw AgentError.fileChanged
            }
            try changed.write(to: url, atomically: true, encoding: .utf8)
            return ToolResult(id: call.id, output: "Файл изменён: \(path)", succeeded: true, exitCode: nil)
        case .command(let command):
            guard approve(.command(command: command, cwd: workspace.path)) else {
                return ToolResult(id: call.id, output: "Команда отклонена пользователем.", succeeded: false, exitCode: nil)
            }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", command]
            process.currentDirectoryURL = workspace
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let output = String(decoding: data, as: UTF8.self)
            return ToolResult(
                id: call.id,
                output: output + "\nКод завершения: \(process.terminationStatus)",
                succeeded: process.terminationStatus == 0,
                exitCode: process.terminationStatus
            )
        }
    }
}

private enum AgentError: LocalizedError {
    case outsideWorkspace
    case invalidReplacement
    case fileChanged
    case duplicateCall(String)

    var errorDescription: String? {
        switch self {
        case .outsideWorkspace: return "Путь находится за пределами проекта."
        case .invalidReplacement: return "Фрагмент для замены должен встречаться в файле ровно один раз."
        case .fileChanged: return "Файл изменился после показа diff. Правка не применена."
        case .duplicateCall(let id): return "Повторный идентификатор вызова инструмента: \(id)"
        }
    }
}
