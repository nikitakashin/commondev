import Darwin
import Foundation

public enum LiveAgentEvent {
    case text(String)
    case toolStarted(id: String, description: String)
    case toolFinished(id: String, result: String)
    case route(String)
    case modelRequest(Int)
    case modelIdentity(model: String?, route: String?)
    case conversation([[String: JSONValue]])
    case notice(String)
}

/// Shared across a parent and its subagents to enforce a total request limit.
public actor ModelRequestBudget {
    private var remaining: Int
    private var remainingTools: Int
    public init(maximum: Int, maxToolCalls: Int? = nil) {
        remaining = max(0, maximum)
        remainingTools = max(0, maxToolCalls ?? maximum * 2)
    }
    /// Reserve requests atomically across parallel children for their parent.
    public func consume(reserving: Int = 0) throws {
        guard remaining > max(0, reserving) else { throw LiveError.limit }
        remaining -= 1
    }

    public func consumeTool() throws {
        guard remainingTools > 0 else { throw LiveError.toolLimit }
        remainingTools -= 1
    }

    public func remainingModelCalls() -> Int { remaining }
}

/// A single live conversation with an OpenAI-compatible model.
public struct LiveAgent {
    private let workspace: URL
    private let global: Bool
    private let readOnly: Bool
    private let client: OpenAICompatibleClient
    private let onEvent: (LiveAgentEvent) async -> Void
    private let approve: (ApprovalRequest) async -> Bool
    private let maxModelCalls: Int
    private let maxToolCalls: Int
    private let systemInstructions: String?
    private let delegate: ((String) async throws -> String)?
    private let requestBudget: ModelRequestBudget
    private let reservedModelCalls: Int
    private let contextByteLimit: Int
    private let onCompaction: (ContextCompaction) async -> Void

    public init(workspace: URL, client: OpenAICompatibleClient, global: Bool = false, readOnly: Bool = false,
                onEvent: @escaping (LiveAgentEvent) async -> Void,
                approve: @escaping (ApprovalRequest) async -> Bool,
                maxModelCalls: Int = 30, maxToolCalls: Int = 60, systemInstructions: String? = nil,
                requestBudget: ModelRequestBudget? = nil,
                reservedModelCalls: Int = 0,
                delegate: ((String) async throws -> String)? = nil,
                contextByteLimit: Int = Self.defaultContextByteLimit,
                onCompaction: @escaping (ContextCompaction) async -> Void = { _ in }) {
        self.workspace = workspace.standardizedFileURL.resolvingSymlinksInPath()
        self.global = global
        self.readOnly = readOnly
        self.client = client
        self.onEvent = onEvent
        self.approve = approve
        self.maxModelCalls = maxModelCalls
        self.maxToolCalls = maxToolCalls
        self.systemInstructions = systemInstructions
        self.requestBudget = requestBudget ?? ModelRequestBudget(maximum: maxModelCalls, maxToolCalls: maxToolCalls)
        self.reservedModelCalls = max(0, reservedModelCalls)
        self.delegate = delegate
        self.contextByteLimit = max(1024, contextByteLimit)
        self.onCompaction = onCompaction
    }

    public static let defaultContextByteLimit = 96_000

    private static func systemMessage(_ instructions: String?, global: Bool) -> [String: JSONValue] {
        let scope = global
            ? "This is a global chat with no project selected. Relative paths and shell commands start in the user's home directory. File tools also accept absolute paths. Supply a directory when searching or inspecting Git and limit inspection to paths relevant to the user's request."
            : "Work in the selected project. Paths are relative to the project."
        return ["role": .string("system"), "content": .string(
            "You are a coding assistant. \(scope) Use the available tools. Explain what you changed and what you verified." +
            (instructions.map { "\n\n" + $0 } ?? "")
        )]
    }

    public static func validateTask(_ task: String, systemInstructions: String?, global: Bool = false,
                                    contextByteLimit: Int = Self.defaultContextByteLimit) throws {
        let user: [String: JSONValue] = ["role": .string("user"), "content": .string(task)]
        _ = try ContextCompactor.fittingToolOutputs([systemMessage(systemInstructions, global: global), user], maxBytes: contextByteLimit)
    }

    public func run(task: String, history: [[String: JSONValue]] = [],
                    resumeCompaction: ContextCompaction? = nil) async throws -> String {
        try Self.validateTask(task, systemInstructions: systemInstructions, global: global, contextByteLimit: contextByteLimit)
        var messages = [Self.systemMessage(systemInstructions, global: global)] + history
        messages.append(["role": .string("user"), "content": .string(task)])
        var usedIDs = Set<String>()
        var state = resumeCompaction
        var callIndex = 0
        func request(
            messages: [[String: JSONValue]], tools: [[String: JSONValue]], reserve: Int = 0,
            onText: @escaping (String) async -> Void = { _ in }
        ) async throws -> OpenAIResponse {
            var retried = false
            while true {
                try Task.checkCancellation()
                guard callIndex < maxModelCalls - reserve else { throw LiveError.limit }
                try await requestBudget.consume(reserving: reservedModelCalls)
                callIndex += 1
                await onEvent(.modelRequest(callIndex))
                do {
                    return try await client.complete(messages: messages, tools: tools, onText: onText)
                } catch OpenAIClientError.retryableTimeout {
                    // One extra attempt, charged to the same shared budget. The
                    // client only marks a timeout safe before any response delta.
                    guard !retried, callIndex < maxModelCalls - reserve else {
                        throw OpenAIClientError.retryableTimeout
                    }
                    retried = true
                    await onEvent(.notice("Модель не ответила вовремя. Повторяем запрос."))
                }
            }
        }
        while callIndex < max(0, maxModelCalls) {
            try Task.checkCancellation()
            let fullHistory = Array(messages.dropFirst())
            var active = ContextCompactor.activeMessages(system: messages[0], history: fullHistory, state: state)
            if try ContextCompactor.encoded(active).count > contextByteLimit,
               let split = try ContextCompactor.splitIndex(in: fullHistory, system: messages[0], maxBytes: contextByteLimit) {
                let previous = state.flatMap { $0.applies(to: fullHistory) ? $0 : nil }
                let start = previous?.coveredCount ?? 0
                if split > start {
                    var summary = previous?.summary ?? ""
                    let boundaries = fullHistory.indices.filter {
                        $0 > start && $0 < split && fullHistory[$0]["role"] == .string("user")
                    } + [split]
                    var turnStart = start
                    for turnEnd in boundaries {
                        let oldMessages = Array(fullHistory[turnStart..<turnEnd])
                        var chunks = ContextCompactor.chunks(try ContextCompactor.encoded(oldMessages),
                                                             maxBytes: min(16_000, contextByteLimit / 3))
                        while !chunks.isEmpty {
                            try Task.checkCancellation()
                            guard callIndex < maxModelCalls - 1 else { throw LiveError.limit }
                            var chunk = chunks.removeFirst()
                            func summaryMessages(_ fragment: String) -> [[String: JSONValue]] { [
                                ["role": .string("system"), "content": .string(
                                    "Summarize earlier coding-agent history for continuation. Preserve user requirements, decisions, important paths, completed actions, errors, unresolved work and uncertainty. Do not invent outcomes. The history may arrive in sequential fragments. Update the previous summary using the fragment. Keep the result concise."
                                )],
                                ["role": .string("user"), "content": .string(
                                    "Previous summary:\n\(summary)\n\nNext history fragment:\n\(fragment)"
                                )]
                            ] }
                            // The fragment is JSON inside another JSON string: escaping
                            // can make it larger than its raw UTF-8 byte count. Split
                            // until the actual encoded summary request fits.
                            while try ContextCompactor.encoded(summaryMessages(chunk)).count > contextByteLimit {
                                let scalars = Array(chunk.unicodeScalars)
                                guard scalars.count > 1 else { throw ContextSizeError.tooLarge }
                                let middle = scalars.count / 2
                                let remainder = String(String.UnicodeScalarView(scalars[middle...]))
                                chunks.insert(remainder, at: 0)
                                chunk = String(String.UnicodeScalarView(scalars[..<middle]))
                            }
                            let response = try await request(messages: summaryMessages(chunk), tools: [], reserve: 1)
                            await onEvent(.modelIdentity(model: response.actualModel, route: response.routedVia))
                            guard response.toolCalls.isEmpty,
                                  !response.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                                  response.text.utf8.count <= min(16_000, contextByteLimit / 2) else {
                                throw LiveError.compactionFailed
                            }
                            summary = response.text
                        }
                        try Task.checkCancellation()
                        // A checkpoint is valid only after a complete user turn and its tool results.
                        let updated = ContextCompaction(coveredCount: turnEnd,
                            coveredDigest: try ContextCompaction.digest(Array(fullHistory.prefix(turnEnd))), summary: summary)
                        state = updated
                        await onCompaction(updated)
                        turnStart = turnEnd
                    }
                    active = ContextCompactor.activeMessages(system: messages[0], history: fullHistory, state: state)
                }
            }
            // A single recent tool result can exceed the context threshold even
            // when there are too few turns to summarize. Keep the full result
            // in messages, and bound only the model-facing copy.
            active = try ContextCompactor.fittingToolOutputs(active, maxBytes: contextByteLimit)
            let response = try await request(messages: active, tools: availableTools) { chunk in
                await onEvent(.text(chunk))
            }
            await onEvent(.modelIdentity(model: response.actualModel, route: response.routedVia))
            if let route = response.routedVia { await onEvent(.route(route)) }
            if response.toolCalls.isEmpty {
                messages.append(["role": .string("assistant"), "content": .string(response.text)])
                await onEvent(.conversation(Array(messages.dropFirst())))
                return response.text
            }
            // Reject an invalid batch before any side effect occurs.
            var batchIDs = Set<String>()
            for call in response.toolCalls {
                guard !usedIDs.contains(call.id), batchIDs.insert(call.id).inserted else {
                    throw LiveError.repeatedCall
                }
            }
            let calls: [JSONValue] = response.toolCalls.map { call in
                .object(["id": .string(call.id), "type": .string("function"),
                         "function": .object(["name": .string(call.name), "arguments": .string(call.argumentsJSON)])])
            }
            messages.append(["role": .string("assistant"), "content": response.text.isEmpty ? .null : .string(response.text),
                             "tool_calls": .array(calls)])
            var completed = 0
            // Parallel children may finish out of order. Keep their results by
            // index so checkpoints remain complete and in protocol order.
            var completedOutOfOrder: [Int: String] = [:]
            func checkpoint() -> [[String: JSONValue]] {
                var history = Array(messages.dropFirst())
                for (offset, pending) in response.toolCalls.dropFirst(completed).enumerated() {
                    history.append(["role": .string("tool"), "tool_call_id": .string(pending.id),
                                    "content": .string(completedOutOfOrder[completed + offset] ?? "Результат неизвестен: выполнение могло начаться до прерывания. Проверьте состояние перед повтором.")])
                }
                return history
            }
            // Persist a protocol-valid uncertain result before starting side effects.
            await onEvent(.conversation(checkpoint()))
            do {
                var index = 0
                while index < response.toolCalls.count {
                    // Only adjacent delegations run concurrently: reads, edits and
                    // commands keep their original ordering around the group.
                    if response.toolCalls[index].name == "delegate_task" {
                        var end = index + 1
                        // Limit simultaneously running snapshots and model requests.
                        while end < response.toolCalls.count && end - index < 2 && response.toolCalls[end].name == "delegate_task" { end += 1 }
                        if end - index > 1 {
                            try await withThrowingTaskGroup(of: (Int, String).self) { group in
                                for childIndex in index..<end {
                                    try Task.checkCancellation()
                                    guard usedIDs.count < maxToolCalls else { throw LiveError.limit }
                                    let call = response.toolCalls[childIndex]
                                    usedIDs.insert(call.id)
                                    try await requestBudget.consumeTool()
                                    await onEvent(.toolStarted(id: call.id, description: call.name))
                                    try Task.checkCancellation()
                                    group.addTask {
                                        do { return (childIndex, try await execute(call)) }
                                        catch is CancellationError { throw CancellationError() }
                                        catch { return (childIndex, "Ошибка: \(error.localizedDescription)") }
                                    }
                                }
                                for try await (childIndex, result) in group {
                                    completedOutOfOrder[childIndex] = result
                                    while let next = completedOutOfOrder.removeValue(forKey: completed) {
                                        let call = response.toolCalls[completed]
                                        messages.append(["role": .string("tool"), "tool_call_id": .string(call.id), "content": .string(next)])
                                        completed += 1
                                    }
                                    await onEvent(.conversation(checkpoint()))
                                    await onEvent(.toolFinished(id: response.toolCalls[childIndex].id, result: result))
                                }
                            }
                            index = end
                            continue
                        }
                    }
                    let call = response.toolCalls[index]
                    try Task.checkCancellation()
                    guard usedIDs.count < maxToolCalls else { throw LiveError.limit }
                    usedIDs.insert(call.id)
                    try await requestBudget.consumeTool()
                    await onEvent(.toolStarted(id: call.id, description: call.name))
                    try Task.checkCancellation()
                    let result: String
                    do { result = try await execute(call) }
                    catch is CancellationError { throw CancellationError() }
                    catch { result = "Ошибка: \(error.localizedDescription)" }
                    messages.append(["role": .string("tool"), "tool_call_id": .string(call.id), "content": .string(result)])
                    completed += 1
                    await onEvent(.conversation(checkpoint()))
                    await onEvent(.toolFinished(id: call.id, result: result))
                    index += 1
                }
            } catch {
                for (offset, call) in response.toolCalls.dropFirst(completed).enumerated() {
                    messages.append(["role": .string("tool"), "tool_call_id": .string(call.id),
                                     "content": .string(completedOutOfOrder[completed + offset] ?? "Выполнение прервано или не началось; действие могло частично выполниться. \(error.localizedDescription)")])
                }
                await onEvent(.conversation(Array(messages.dropFirst())))
                throw error
            }
        }
        throw LiveError.limit
    }

    private func execute(_ call: OpenAIToolCall) async throws -> String {
        if readOnly, Self.mutatingTools.contains(call.name) { throw LiveError.unknownTool }
        guard let data = call.argumentsJSON.data(using: .utf8),
              let args = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LiveError.arguments
        }
        switch call.name {
        case "delegate_task":
            guard let task = args["task"] as? String, !task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let delegate else { throw LiveError.arguments }
            do {
                return try await delegate(task)
            } catch is CancellationError {
                // Stopping one child should return control to the main agent.
                // Cancelling the parent must still stop the entire run.
                try Task.checkCancellation()
                return "Субагент остановлен пользователем; задача не завершена."
            }
        case "read_file":
            guard let path = args["path"] as? String else { throw LiveError.arguments }
            let offset = args["offset_bytes"] as? Int ?? 0
            let count = args["max_bytes"] as? Int ?? 64_000
            guard (args["offset_bytes"] == nil || args["offset_bytes"] is Int),
                  (args["max_bytes"] == nil || args["max_bytes"] is Int),
                  offset >= 0, (4...1_000_000).contains(count) else { throw LiveError.arguments }
            return try readTextFile(fileURL(path), range: (offset, count))
        case "find_files":
            guard let pattern = args["pattern"] as? String, !pattern.isEmpty else { throw LiveError.arguments }
            return try WorkspaceSearch.find(pattern: pattern, workspace: toolDirectory(args))
        case "search_files":
            guard let query = args["query"] as? String, !query.isEmpty else { throw LiveError.arguments }
            return try WorkspaceSearch.search(query: query, workspace: toolDirectory(args))
        case "git_diff":
            return try await WorkspaceGit.diff(workspace: toolDirectory(args))
        case "git_history":
            return try await WorkspaceGit.history(workspace: toolDirectory(args))
        case "create_file":
            guard let path = args["path"] as? String, let contents = args["contents"] as? String else { throw LiveError.arguments }
            let url = try fileURL(path)
            let diff = "--- /dev/null\n+++ b/\(path)\n" + contents.components(separatedBy: "\n").map { "+" + $0 }.joined(separator: "\n")
            guard await approve(.edit(path: path, diff: diff)) else { return "Создание файла отклонено пользователем." }
            try Task.checkCancellation()
            // Re-resolve after approval to detect a changed symlink. O_EXCL prevents overwriting.
            guard try fileURL(path) == url else { throw LiveError.changed }
            let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, S_IRUSR | S_IWUSR | S_IRGRP | S_IROTH)
            guard fd >= 0 else {
                if errno == EEXIST { throw LiveError.exists }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            do {
                try handle.write(contentsOf: Data(contents.utf8))
                try handle.close()
            } catch {
                try? handle.close()
                try? FileManager.default.removeItem(at: url)
                throw error
            }
            return "Файл создан: \(path)"
        case "replace_text":
            guard let path = args["path"] as? String, let old = args["old"] as? String,
                  let new = args["new"] as? String, !old.isEmpty else { throw LiveError.arguments }
            let url = try fileURL(path)
            let original = try readTextFile(url)
            let parts = original.components(separatedBy: old)
            guard parts.count == 2 else { throw LiveError.replacement }
            let proposed = parts[0] + new + parts[1]
            let removed = old.components(separatedBy: "\n").map { "-" + $0 }.joined(separator: "\n")
            let added = new.components(separatedBy: "\n").map { "+" + $0 }.joined(separator: "\n")
            let diff = "--- a/\(path)\n+++ b/\(path)\n\(removed)\n\(added)"
            guard await approve(.edit(path: path, diff: diff)) else { return "Правка отклонена пользователем." }
            try Task.checkCancellation()
            // The user approved a diff for this exact resolved target. A link
            // may have been redirected while the approval sheet was open, even
            // if the new target happens to have identical contents.
            guard try fileURL(path) == url,
                  try readTextFile(url) == original else { throw LiveError.changed }
            try proposed.write(to: url, atomically: true, encoding: .utf8)
            return "Файл изменён: \(path)"
        case "run_command":
            guard let command = args["command"] as? String else { throw LiveError.arguments }
            guard await approve(.command(command: command, cwd: workspace.path)) else {
                return "Команда отклонена пользователем."
            }
            try Task.checkCancellation()
            return try await CommandRunner.run(command, cwd: workspace)
        default: throw LiveError.unknownTool
        }
    }

    private func fileURL(_ path: String) throws -> URL {
        if global {
            let expanded = (path as NSString).expandingTildeInPath
            let url = expanded.hasPrefix("/") ? URL(fileURLWithPath: expanded) : workspace.appendingPathComponent(expanded)
            return url.standardizedFileURL.resolvingSymlinksInPath()
        }
        guard !path.hasPrefix("/") else { throw LiveError.path }
        let resolved = workspace.appendingPathComponent(path).standardizedFileURL.resolvingSymlinksInPath()
        guard resolved.path.hasPrefix(workspace.path + "/") else { throw LiveError.path }
        return resolved
    }

    private func toolDirectory(_ args: [String: Any]) throws -> URL {
        guard global else { return workspace }
        guard let directory = args["directory"] as? String, !directory.isEmpty else { throw LiveError.arguments }
        return try fileURL(directory)
    }

    /// Bound memory use and never block opening a FIFO or device. Search remains
    /// available to find relevant lines in files that exceed this limit.
    private func readTextFile(_ url: URL, range: (offset: Int, count: Int)? = nil) throws -> String {
        let limit = 1_000_000
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard (info.st_mode & S_IFMT) == S_IFREG else { throw LiveError.notRegularFile }
        guard range != nil || info.st_size <= limit else { throw LiveError.fileTooLarge }
        let offset = range?.offset ?? 0
        guard offset <= info.st_size else { throw LiveError.arguments }
        let requested = range?.count ?? limit + 1
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while data.count < requested {
            try Task.checkCancellation()
            let count = pread(descriptor, &buffer, min(buffer.count, requested - data.count), off_t(offset + data.count))
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            data.append(contentsOf: buffer.prefix(count))
        }
        if range == nil {
            guard data.count <= limit else { throw LiveError.fileTooLarge }
            guard let text = String(data: data, encoding: .utf8) else { throw LiveError.nonTextFile }
            return text
        }
        // A chunk can end in the middle of a UTF-8 scalar. Trim only that
        // incomplete tail and expose the exact next byte offset to the model.
        let moreBytesExist = offset + data.count < info.st_size
        var text = String(data: data, encoding: .utf8)
        if text == nil && moreBytesExist {
            for _ in 0..<min(3, data.count) {
                data.removeLast()
                if let decoded = String(data: data, encoding: .utf8) { text = decoded; break }
            }
        }
        guard let text, !data.isEmpty || offset == info.st_size else { throw LiveError.nonTextFile }
        let next = offset + data.count
        guard offset > 0 || next < info.st_size else { return text }
        let nextPart = next < info.st_size ? " Для продолжения вызовите read_file с offset_bytes=\(next)." : " Конец файла."
        return text + "\n[Фрагмент файла: байты \(offset)..<\(next) из \(info.st_size).\(nextPart)]"
    }

    private static let tools: [[String: JSONValue]] = [
        tool("find_files", "Find project files matching a filename glob", properties: ["pattern": "Filename glob such as *.swift"], required: ["pattern"]),
        tool("search_files", "Search project text files for a literal string", properties: ["query": "Text to search"], required: ["query"]),
        tool("read_file", "Read a UTF-8 file in chunks. If a continuation offset is returned, request the next chunk with offset_bytes.", properties: ["path": "Relative path", "offset_bytes": "Byte offset from the beginning, default 0", "max_bytes": "Maximum bytes to read (4 to 1000000; default 64000)"], required: ["path"], integerProperties: ["offset_bytes", "max_bytes"]),
        tool("git_diff", "Show staged and unstaged changes and untracked files within the project", properties: [:], required: []),
        tool("git_history", "Show recent Git commits affecting the project", properties: [:], required: []),
        tool("create_file", "Create a new UTF-8 file without replacing an existing file", properties: ["path": "Relative path", "contents": "Complete file contents"], required: ["path", "contents"]),
        tool("replace_text", "Replace exactly one occurrence in a file", properties: ["path": "Relative path", "old": "Exact text", "new": "Replacement"], required: ["path", "old", "new"]),
        tool("run_command", "Run a shell command in the project", properties: ["command": "Shell command"], required: ["command"])
    ]
    private static let delegateTool = tool("delegate_task", "Delegate a self-contained task to a subagent and receive its report", properties: ["task": "Specific task for the subagent"], required: ["task"])

    private static let mutatingTools: Set<String> = ["create_file", "replace_text", "run_command", "delegate_task"]
    private static let directoryTools: Set<String> = ["find_files", "search_files", "git_diff", "git_history"]

    private var availableTools: [[String: JSONValue]] {
        var tools = Self.tools.compactMap { tool -> [String: JSONValue]? in
            guard case var .object(function) = tool["function"], case let .string(name) = function["name"] else { return tool }
            if readOnly && Self.mutatingTools.contains(name) { return nil }
            guard global, Self.directoryTools.contains(name),
                  case var .object(parameters) = function["parameters"],
                  case var .object(properties) = parameters["properties"],
                  case var .array(required) = parameters["required"] else { return tool }
            properties["directory"] = .object(["type": .string("string"),
                                               "description": .string("Directory to inspect, absolute or relative to the home directory")])
            required.append(.string("directory"))
            parameters["properties"] = .object(properties)
            parameters["required"] = .array(required)
            function["parameters"] = .object(parameters)
            return ["type": .string("function"), "function": .object(function)]
        }
        if delegate != nil && !readOnly { tools.append(Self.delegateTool) }
        return tools
    }

    private static func tool(_ name: String, _ description: String, properties: [String: String], required: [String], integerProperties: Set<String> = []) -> [String: JSONValue] {
        let fields = properties.mapValues { JSONValue.object(["type": .string("string"), "description": .string($0)]) }
            .merging(Dictionary(uniqueKeysWithValues: integerProperties.compactMap { key in
                properties[key].map { (key, JSONValue.object(["type": .string("integer"), "description": .string($0)])) }
            }), uniquingKeysWith: { _, integer in integer })
        return ["type": .string("function"), "function": .object([
            "name": .string(name), "description": .string(description),
            "parameters": .object(["type": .string("object"), "properties": .object(fields),
                                   "required": .array(required.map(JSONValue.string))])
        ])]
    }
}

private enum LiveError: LocalizedError {
    case arguments, path, replacement, changed, exists, unknownTool, repeatedCall, limit, toolLimit, compactionFailed
    case fileTooLarge, notRegularFile, nonTextFile
    var errorDescription: String? {
        switch self {
        case .arguments: return "Некорректные аргументы инструмента."
        case .path: return "Путь за пределами проекта."
        case .replacement: return "Текст для замены должен встречаться ровно один раз."
        case .changed: return "Файл изменился после показа правки."
        case .exists: return "Файл уже существует."
        case .unknownTool: return "Неизвестный инструмент."
        case .repeatedCall: return "Повторный ID инструмента."
        case .limit: return "Достигнут лимит обращений к модели."
        case .toolLimit: return "Достигнут общий лимит вызовов инструментов."
        case .compactionFailed: return "Не удалось сохранить краткое содержание контекста. История осталась без изменений."
        case .fileTooLarge: return "Файл превышает лимит 1 МБ для правки через replace_text. Читать его можно частями через read_file."
        case .notRegularFile: return "Можно читать и редактировать только обычные файлы."
        case .nonTextFile: return "Файл не является текстом UTF-8."
        }
    }
}
