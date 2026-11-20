import Foundation
import AgentCore
import CryptoKit
import HarnessCore

public enum LiveHarnessError: LocalizedError {
    case unverifiedModel, emptyProposal, validationDenied, processFailure, untrustedTests

    public var errorDescription: String? {
        switch self {
        case .unverifiedModel: return "Нельзя подтвердить фактический маршрут и модель."
        case .emptyProposal: return "Модель не предложила новые инструкции."
        case .validationDenied: return "Запуск независимой проверки отклонён."
        case .processFailure: return "Не удалось запустить независимую проверку."
        case .untrustedTests: return "Проверочные файлы отсутствуют или были изменены."
        }
    }
}

private actor RunTelemetry {
    var calls = 0
    var identities: [(String?, String?)] = []
    var trace = ""

    func record(_ event: LiveAgentEvent) {
        switch event {
        case .notice(let text): trace += "\n" + text
        case .modelRequest: calls += 1
        case .modelIdentity(let model, let route): identities.append((model, route))
        case .text(let text): trace += text
        case .toolStarted(let id, let description): trace += "\n[" + id + "] " + description
        case .toolFinished(let id, let result): trace += "\n[" + id + "] " + result
        case .route, .conversation: break
        }
    }

    func result(expected: HarnessRoute) throws -> HarnessRun {
        // A successful LiveAgent run may include a retryable timeout before any
        // response data. That attempt consumes budget but cannot report a model
        // identity. Validate every response that did arrive, while retaining the
        // actual number of attempts in the experiment budget.
        guard calls > 0, !identities.isEmpty, identities.count <= calls,
              identities.allSatisfy({ $0.0 == expected.model && $0.1 == expected.provider }) else {
            throw LiveHarnessError.unverifiedModel
        }
        return HarnessRun(route: expected, modelCalls: calls, trace: trace)
    }
}

/// The caller supplies trusted test commands and the same approval policy used in the app.
public struct LiveHarnessExecutor: HarnessExecutor {
    private let client: OpenAICompatibleClient
    private let verificationCommands: [String: String]
    private let approve: @Sendable (ApprovalRequest) async -> Bool

    public init(client: OpenAICompatibleClient, verificationCommands: [String: String], approve: @escaping @Sendable (ApprovalRequest) async -> Bool) {
        self.client = client
        self.verificationCommands = verificationCommands
        self.approve = approve
    }

    public func run(task: HarnessTask, workspace: URL, profile: HarnessProfile, route: HarnessRoute, maxModelCalls: Int) async throws -> HarnessRun {
        let telemetry = RunTelemetry()
        let agent = LiveAgent(workspace: workspace, client: client,
                              onEvent: { await telemetry.record($0) }, approve: approve,
                              maxModelCalls: maxModelCalls, systemInstructions: profile.instructions)
        let output = try await agent.run(task: task.prompt)
        let result = try await telemetry.result(expected: route)
        return HarnessRun(route: result.route, modelCalls: result.modelCalls, trace: result.trace + "\n" + output)
    }

    public func propose(baseline: HarnessProfile, evidence: [HarnessEvidence], route: HarnessRoute, maxModelCalls: Int) async throws -> (profile: HarnessProfile, run: HarnessRun) {
        guard maxModelCalls > 0 else { throw HarnessError.budgetExceeded }
        let traces = evidence.map {
            "Задача: " + $0.task + "\nНезависимая проверка: " +
            ($0.verificationPassed ? "пройдена" : "не пройдена") + "\n" + $0.trace
        }.joined(separator: "\n\n")
        let response = try await client.complete(messages: [
            ["role": .string("system"), "content": .string("Улучши инструкции coding-агента по приведённым результатам. Верни только полный новый текст инструкций, без Markdown-ограждения.")],
            ["role": .string("user"), "content": .string("Текущие инструкции:\n" + baseline.instructions + "\n\nРезультаты:\n" + traces)]
        ], tools: [])
        guard response.actualModel == route.model, response.routedVia == route.provider else { throw LiveHarnessError.unverifiedModel }
        let proposed = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !proposed.isEmpty, response.toolCalls.isEmpty else { throw LiveHarnessError.emptyProposal }
        return (HarnessProfile(instructions: proposed), HarnessRun(route: route, modelCalls: 1, trace: proposed))
    }

    public func verify(task: HarnessTask, workspace: URL) async throws -> Bool {
        guard let command = verificationCommands[task.name] else { throw LiveHarnessError.processFailure }
        let trustedFiles = try protectedFiles(in: task.fixture)
        guard !trustedFiles.isEmpty, trustedFiles == (try protectedFiles(in: workspace)) else {
            throw LiveHarnessError.untrustedTests
        }
        guard await approve(.command(command: command, cwd: workspace.path)) else { throw LiveHarnessError.validationDenied }
        let result = try await CommandRunner.runResult(command, cwd: workspace)
        guard trustedFiles == (try protectedFiles(in: workspace)),
              trustedFiles == (try protectedFiles(in: task.fixture)) else {
            throw LiveHarnessError.untrustedTests
        }
        return result.exitCode == 0
    }

    private func protectedFiles(in root: URL) throws -> [String: String] {
        let rootPath = root.standardizedFileURL.path
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else { throw LiveHarnessError.untrustedTests }
        var hashes: [String: String] = [:]
        var testCount = 0
        for case let file as URL in enumerator {
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey])
            if values.isDirectory == true && ["node_modules", "build", "dist", "__pycache__"].contains(file.lastPathComponent) {
                enumerator.skipDescendants()
                continue
            }
            let relative = String(file.standardizedFileURL.path.dropFirst(rootPath.count + 1))
            let components = relative.lowercased().split(separator: "/")
            let testFile = components.contains(where: { ["tests", "test", "__tests__"].contains(String($0)) })
                || file.lastPathComponent.lowercased().contains("test")
            let manifest = ["Package.swift", "Package.resolved", "package.json", "package-lock.json",
                            "pyproject.toml", "pytest.ini", "Cargo.toml", "Cargo.lock"].contains(file.lastPathComponent)
            guard testFile || manifest else { continue }
            if values.isSymbolicLink == true { throw LiveHarnessError.untrustedTests }
            guard values.isRegularFile == true else { continue }
            if testFile { testCount += 1 }
            let data = try Data(contentsOf: file)
            hashes[relative] = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
        guard testCount > 0 else { throw LiveHarnessError.untrustedTests }
        return hashes
    }
}

