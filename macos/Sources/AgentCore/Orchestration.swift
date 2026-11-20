import Foundation

public enum SubagentEvent {
    case started(id: UUID, task: String)
    case activity(id: UUID, event: LiveAgentEvent)
    case finished(id: UUID, result: String)
    case failed(id: UUID, reason: String)
}

public enum UltracodeEvent {
    case planning
    case phase(String)
    case subagent(SubagentEvent)
    case main(LiveAgentEvent)
    case review(LiveAgentEvent)
}

public struct UltracodeResult {
    public let answer: String
    public let review: String
    public let research: [String]
}

public enum OrchestrationError: LocalizedError {
    case budget
    case invalidPlan
    case missingWorkspace

    public var errorDescription: String? {
        switch self {
        case .budget: return "Для Ultracode недостаточно бюджета запросов."
        case .invalidPlan: return "Модель не вернула план из одной или двух задач."
        case .missingWorkspace: return "Папка проекта недоступна."
        }
    }
}

/// Keeps cancellable handles for the child agents shown in the interface.
public actor SubagentRegistry {
    private var tasks: [UUID: Task<String, Error>] = [:]
    public init() {}

    public func run(id: UUID, operation: @escaping () async throws -> String) async throws -> String {
        let worker = Task { try await operation() }
        tasks[id] = worker
        defer { tasks[id] = nil }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    public func cancel(_ id: UUID) { tasks[id]?.cancel() }
}

/// A child runs in a fresh project snapshot. Its task can be cancelled independently
/// by cancelling the Swift Task that calls this function.
public enum SubagentRunner {
    public static func run(
        id: UUID, task: String, workspace: URL, client: OpenAICompatibleClient,
        maxModelCalls: Int,
        requestBudget: ModelRequestBudget? = nil,
        reservedModelCalls: Int = 0,
        global: Bool = false,
        readOnly: Bool = false,
        systemInstructions: String = "",
        onEvent: @escaping (SubagentEvent) async -> Void,
        approve: @escaping (UUID, ApprovalRequest) async -> Bool
    ) async throws -> String {
        guard maxModelCalls > 0 else { throw OrchestrationError.budget }
        let researchOnly = global || readOnly
        let copy = researchOnly ? nil : try ProjectSnapshot.make(from: workspace)
        defer { if let copy { try? FileManager.default.removeItem(at: copy) } }
        let baseline = try copy.map { try ProjectSnapshot.make(from: $0) }
        defer { if let baseline { try? FileManager.default.removeItem(at: baseline) } }
        let scope = researchOnly
            ? "You are a read-only research subagent. Report findings and relevant paths to your parent."
            : "You are a subagent working in an isolated copy. Report findings and relevant paths to your parent. Your changes are returned to the parent for review and are not applied directly to the original project."
        await onEvent(.started(id: id, task: task))
        let agent = LiveAgent(
            workspace: copy ?? workspace, client: client, global: global, readOnly: researchOnly,
            onEvent: { await onEvent(.activity(id: id, event: $0)) },
            approve: { await approve(id, $0) },
            maxModelCalls: maxModelCalls,
            systemInstructions: "\(scope)\n\(systemInstructions)",
            requestBudget: requestBudget,
            reservedModelCalls: reservedModelCalls
        )
        do {
            let answer = try await agent.run(task: task)
            let changes = if let baseline, let copy {
                try ProjectSnapshot.changes(from: baseline, to: copy)
            } else { "" }
            let result = changes.isEmpty ? answer : answer + "\n\nИзменения в копии субагента:\n" + changes
            await onEvent(.finished(id: id, result: result))
            return result
        } catch {
            await onEvent(.failed(id: id, reason: error.localizedDescription))
            throw error
        }
    }
}

/// Plans a task, runs independent researchers, then implements and reviews it.
public enum UltracodeRunner {
    public static func run(
        task: String, workspace: URL, client: OpenAICompatibleClient,
        maxModelCalls: Int,
        global: Bool = false,
        readOnly: Bool = false,
        systemInstructions: String = "",
        history: [[String: JSONValue]] = [],
        resumeCompaction: ContextCompaction? = nil,
        onCompaction: @escaping (ContextCompaction) async -> Void = { _ in },
        registry: SubagentRegistry? = nil,
        onEvent: @escaping (UltracodeEvent) async -> Void,
        approve: @escaping (UUID?, ApprovalRequest) async -> Bool
    ) async throws -> UltracodeResult {
        // Reserve five calls per agent for research, tool results and a final
        // response. The caller chooses the total budget explicitly.
        guard maxModelCalls >= 16 else { throw OrchestrationError.budget }
        let effectiveBudget = maxModelCalls
        let canonicalWorkspace = workspace.standardizedFileURL.resolvingSymlinksInPath()
        let context = global
            ? "There is no project root. Scope research to the paths or goal mentioned by the user."
            : "Project file paths:\n\(try WorkspaceSearch.find(pattern: "*", workspace: canonicalWorkspace))"
        await onEvent(.planning)
        let plan = try await client.complete(messages: [
            ["role": .string("system"), "content": .string("Divide the coding request into one or two independent, read-only research tasks. Use the supplied context and the user's request. Do not invent functions, modules or behavior. Ask researchers to inspect actual files. Return only JSON with shape {\"tasks\":[\"...\"]}.")],
            ["role": .string("user"), "content": .string("Request:\n\(task)\n\n\(context)")]
        ], tools: [])
        let parsedPlan = planTasks(plan.text, request: task)
        if parsedPlan.usedFallback {
            await onEvent(.phase("План не распознан, запускаем общее исследование"))
        }
        let proposedTasks = parsedPlan.tasks
        // Two researchers need at least seven requests each, in addition to
        // the planner and the five-call reserves for implementation and review.
        let tasks = Array(proposedTasks.prefix(effectiveBudget >= 25 ? 2 : 1))
        let requestBudget = ModelRequestBudget(maximum: effectiveBudget - 1, maxToolCalls: effectiveBudget * 2)
        // Keep five calls each for the main agent and reviewer. Parallel
        // researchers receive equal shares of the remainder.
        let researchBudget = (effectiveBudget - 1 - 10) / tasks.count

        await onEvent(.phase("Параллельное исследование"))
        let outcomes = try await withThrowingTaskGroup(of: (Int, String).self) { group in
            for (index, childTask) in tasks.enumerated() {
                group.addTask {
                    let id = UUID()
                    do {
                        let operation = {
                            try await SubagentRunner.run(
                            id: id, task: childTask, workspace: workspace, client: client, maxModelCalls: researchBudget,
                            requestBudget: requestBudget,
                            global: global,
                            readOnly: readOnly,
                            systemInstructions: systemInstructions,
                            onEvent: { await onEvent(.subagent($0)) },
                            approve: { id, request in await approve(id, request) }
                            )
                        }
                        let answer: String
                        if let registry { answer = try await registry.run(id: id, operation: operation) }
                        else { answer = try await operation() }
                        return (index, answer)
                    } catch is CancellationError {
                        if Task.isCancelled { throw CancellationError() }
                        return (index, "Исследование остановлено пользователем.")
                    } catch {
                        return (index, "Исследование не завершено: \(error.localizedDescription)")
                    }
                }
            }
            var results: [(Int, String)] = []
            for try await result in group { results.append(result) }
            return results.sorted { $0.0 < $1.0 }.map(\.1)
        }

        try Task.checkCancellation()
        await onEvent(.phase(readOnly ? "Подготовка плана" : "Выполнение задачи"))
        // Unused research calls remain available to the main agent. Reserve
        // five for the final review, whose limit becomes the true remainder.
        let mainBudget = await requestBudget.remainingModelCalls() - 5
        let notes = zip(tasks, outcomes).map { "Задача: \($0.0)\nРезультат: \($0.1)" }.joined(separator: "\n\n")
        let nextStep = readOnly ? "Propose a plan for the user's request." : "Perform the user's request."
        let main = LiveAgent(
            workspace: workspace, client: client, global: global, readOnly: readOnly, onEvent: { await onEvent(.main($0)) },
            approve: { await approve(nil, $0) }, maxModelCalls: mainBudget,
            systemInstructions: "\(systemInstructions)\nConsider the following subagent research and verify it as needed. \(nextStep)\n\(notes)",
            requestBudget: requestBudget,
            onCompaction: onCompaction
        )
        let answer = try await main.run(task: task, history: history, resumeCompaction: resumeCompaction)
        try Task.checkCancellation()
        await onEvent(.phase("Независимая проверка"))
        let reviewID = UUID()
        let reviewBudget = await requestBudget.remainingModelCalls()
        let review: String
        let reviewFocus = readOnly
            ? "Review the proposed plan for gaps. Inspect relevant files and report missing steps."
            : "Review the completed task below. Inspect the current files and identify mistakes or missing verification. Summarize concrete findings."
        do {
            let operation = {
                try await SubagentRunner.run(
                id: reviewID,
                task: "\(reviewFocus)\n\(task)\nAgent report: \(answer)",
                workspace: workspace, client: client, maxModelCalls: reviewBudget,
                requestBudget: requestBudget,
                global: global,
                readOnly: readOnly,
                systemInstructions: systemInstructions,
                onEvent: { event in
                    await onEvent(.subagent(event))
                    if case .activity(_, let activity) = event { await onEvent(.review(activity)) }
                },
                approve: { id, request in await approve(id, request) }
                )
            }
            if let registry { review = try await registry.run(id: reviewID, operation: operation) }
            else { review = try await operation() }
        } catch is CancellationError {
            if Task.isCancelled { throw CancellationError() }
            review = "Независимая проверка остановлена пользователем."
        } catch {
            review = "Независимая проверка не завершена: \(error.localizedDescription)"
        }
        return UltracodeResult(answer: answer, review: review, research: outcomes)
    }

    /// Extract the first valid task object from plain JSON, a code fence, or
    /// explanatory prose. Text inside JSON strings may contain braces.
    static func planTasks(_ text: String, request: String) -> (tasks: [String], usedFallback: Bool) {
        let bounded = String(text.prefix(32_000))
        var start: String.Index?
        var depth = 0
        var inString = false
        var escaped = false
        for index in bounded.indices {
            let char = bounded[index]
            if start == nil {
                if char == "{" {
                    start = index
                    depth = 1
                }
                continue
            }
            if inString {
                if escaped { escaped = false }
                else if char == "\\" { escaped = true }
                else if char == "\"" { inString = false }
            } else if char == "\"" {
                inString = true
            } else if char == "{" {
                depth += 1
            } else if char == "}" {
                depth -= 1
                if depth == 0, let objectStart = start {
                    let candidate = String(bounded[objectStart...index])
                    if let data = candidate.data(using: .utf8),
                       let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let tasks = object["tasks"] as? [String] {
                        let cleaned = tasks.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                            .filter { !$0.isEmpty }
                        if !cleaned.isEmpty { return (Array(cleaned.prefix(2)), false) }
                    }
                    start = nil
                    depth = 0
                    inString = false
                    escaped = false
                }
            }
        }
        return (["Inspect the actual project files relevant to this request and report concrete findings. Do not edit files or assume facts. Request: " + request], true)
    }

}

private enum ProjectSnapshot {
    /// Return changes for the parent agent to inspect and apply through normal approvals.
    static func changes(from baseline: URL, to updated: URL) throws -> String {
        let oldFiles = try files(in: baseline)
        let newFiles = try files(in: updated)
        let paths = Set(oldFiles.keys).union(newFiles.keys).sorted()
        var result = ""
        let limit = 32_000
        for path in paths {
            try Task.checkCancellation()
            let old = try oldFiles[path].map { try Data(contentsOf: $0, options: .mappedIfSafe) }
            let new = try newFiles[path].map { try Data(contentsOf: $0, options: .mappedIfSafe) }
            guard old != new else { continue }
            let heading = "--- " + (old == nil ? "/dev/null" : "a/" + path) +
                "\n+++ " + (new == nil ? "/dev/null" : "b/" + path) + "\n"
            var section = heading
            if (old?.count ?? 0) + (new?.count ?? 0) > limit / 2 {
                section += "[Файл слишком велик для передачи изменений; запросите более узкую задачу.]\n"
                result += section
                continue
            }
            if let old, let text = String(data: old, encoding: .utf8), !text.contains("\0") {
                section += text.components(separatedBy: "\n").map { "-" + $0 }.joined(separator: "\n") + "\n"
            } else if old != nil { section += "[Исходный файл двоичный]\n" }
            if let new, let text = String(data: new, encoding: .utf8), !text.contains("\0") {
                section += text.components(separatedBy: "\n").map { "+" + $0 }.joined(separator: "\n") + "\n"
            } else if new != nil { section += "[Новый файл двоичный]\n" }
            guard result.utf8.count + section.utf8.count <= limit else {
                result += "\nСписок изменений сокращён из-за размера; запросите более узкую задачу.\n"
                return result
            }
            result += section
        }
        return result
    }

    private static func files(in directory: URL) throws -> [String: URL] {
        let root = directory.standardizedFileURL.resolvingSymlinksInPath()
        guard let items = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
        ) else { throw OrchestrationError.missingWorkspace }
        var result: [String: URL] = [:]
        for case let item as URL in items {
            try Task.checkCancellation()
            let values = try item.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
            if values.isSymbolicLink == true { items.skipDescendants(); continue }
            if values.isDirectory == true && [".git", ".build", "node_modules"].contains(item.lastPathComponent) {
                items.skipDescendants()
                continue
            }
            guard values.isRegularFile == true else { continue }
            let path = item.standardizedFileURL.resolvingSymlinksInPath().path
            guard path.hasPrefix(root.path + "/") else { throw OrchestrationError.missingWorkspace }
            result[String(path.dropFirst(root.path.count + 1))] = item
        }
        return result
    }

    static func make(from source: URL) throws -> URL {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: source.path, isDirectory: &isDirectory), isDirectory.boolValue
        else { throw OrchestrationError.missingWorkspace }
        let root = source.standardizedFileURL.resolvingSymlinksInPath()
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("commondev-agent-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        do {
            var enumerationError: Error?
            guard let items = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey],
                options: [], errorHandler: { _, error in
                    enumerationError = error
                    return false
                }
            ) else { throw OrchestrationError.missingWorkspace }
            for case let item as URL in items {
                try Task.checkCancellation()
                let properties = try item.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
                if properties.isSymbolicLink == true { continue }
                let resolvedPath = item.standardizedFileURL.resolvingSymlinksInPath().path
                guard resolvedPath.hasPrefix(root.path + "/") else { throw OrchestrationError.missingWorkspace }
                let relative = String(resolvedPath.dropFirst(root.path.count + 1))
                if properties.isDirectory == true && [".git", ".build", "node_modules"].contains(item.lastPathComponent) {
                    items.skipDescendants()
                    continue
                }
                let target = destination.appendingPathComponent(relative)
                if properties.isDirectory == true {
                    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
                } else if properties.isRegularFile == true {
                    try FileManager.default.copyItem(at: item, to: target)
                }
            }
            if let enumerationError { throw enumerationError }
            return destination
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }
}
