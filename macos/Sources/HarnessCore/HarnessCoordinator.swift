import Foundation

public struct HarnessProfile: Codable, Equatable, Sendable {
    public let id: UUID
    public let instructions: String
    public init(id: UUID = UUID(), instructions: String) {
        self.id = id
        self.instructions = instructions
    }
}

public struct HarnessTask: Sendable {
    public let name: String
    public let prompt: String
    public let fixture: URL
    public init(name: String, prompt: String, fixture: URL) {
        self.name = name
        self.prompt = prompt
        self.fixture = fixture
    }
}

/// Identifies the actual provider and model, never an automatic routing alias.
public struct HarnessRoute: Codable, Equatable, Sendable {
    public let provider: String
    public let model: String
    public init(provider: String, model: String) {
        self.provider = provider
        self.model = model
    }
}

public struct HarnessRun: Sendable {
    public let route: HarnessRoute
    public let modelCalls: Int
    public let trace: String
    public init(route: HarnessRoute, modelCalls: Int, trace: String) {
        self.route = route
        self.modelCalls = modelCalls
        self.trace = trace
    }
}

public struct HarnessEvidence: Sendable {
    public let task: String
    public let trace: String
    public let verificationPassed: Bool
}

public struct HarnessComparison: Sendable {
    public let task: String
    public let baselinePassed: Bool
    public let candidatePassed: Bool
}

public struct HarnessReport: Sendable {
    public let candidate: HarnessProfile
    public let comparisons: [HarnessComparison]
    public let accepted: Bool
    public let modelCalls: Int
}

public enum HarnessError: LocalizedError {
    case disabled, busy, missingTasks, overlappingTasks, duplicateTaskNames, budgetExceeded, routeChanged, invalidUsage, noImprovement, invalidFixture

    public var errorDescription: String? {
        switch self {
        case .disabled: return "Harness² выключен."
        case .busy: return "Эксперимент уже выполняется."
        case .missingTasks: return "Нужны задачи для разработки и независимой проверки."
        case .overlappingTasks: return "Папки отложенных и тренировочных задач не должны совпадать или содержать друг друга."
        case .duplicateTaskNames: return "У каждой задачи должно быть уникальное имя для независимой проверки."
        case .budgetExceeded: return "Исчерпан бюджет эксперимента."
        case .routeChanged: return "Фактическая модель или провайдер изменились во время эксперимента."
        case .invalidUsage: return "Исполнитель вернул недопустимое количество запросов."
        case .noImprovement: return "Предложенный профиль совпадает с исходным."
        case .invalidFixture: return "Папка контрольной задачи недоступна."
        }
    }
}

/// Implementations run the real agent and separate trusted checks.
/// The host must enforce maxModelCalls before each model request.
public protocol HarnessExecutor: Sendable {
    func run(task: HarnessTask, workspace: URL, profile: HarnessProfile, route: HarnessRoute, maxModelCalls: Int) async throws -> HarnessRun
    func propose(baseline: HarnessProfile, evidence: [HarnessEvidence], route: HarnessRoute, maxModelCalls: Int) async throws -> (profile: HarnessProfile, run: HarnessRun)
    /// Infrastructure failures throw; a failed independent check returns false.
    func verify(task: HarnessTask, workspace: URL) async throws -> Bool
}

/// Owns enabled state and an accepted profile for one project.
public actor HarnessCoordinator {
    private let profileURL: URL
    private let executor: any HarnessExecutor
    private var enabled = false
    private var running: Task<HarnessReport, Error>?
    private var generation = 0

    public init(profileURL: URL, executor: any HarnessExecutor) {
        self.profileURL = profileURL
        self.executor = executor
    }

    public func setEnabled(_ enabled: Bool) {
        self.enabled = enabled
        if !enabled {
            generation += 1
            running?.cancel()
        }
    }

    public func activeProfile(standard: HarnessProfile) throws -> HarnessProfile {
        guard enabled, FileManager.default.fileExists(atPath: profileURL.path) else { return standard }
        return try JSONDecoder().decode(HarnessProfile.self, from: Data(contentsOf: profileURL))
    }

    public func experiment(
        baseline: HarnessProfile, training: [HarnessTask], heldOut: [HarnessTask],
        route: HarnessRoute, maxModelCalls: Int
    ) async throws -> HarnessReport {
        guard enabled else { throw HarnessError.disabled }
        guard running == nil else { throw HarnessError.busy }
        guard !training.isEmpty, !heldOut.isEmpty else { throw HarnessError.missingTasks }
        let trainingFixtures = training.map { $0.fixture.standardizedFileURL.resolvingSymlinksInPath().pathComponents }
        let heldOutFixtures = heldOut.map { $0.fixture.standardizedFileURL.resolvingSymlinksInPath().pathComponents }
        guard heldOutFixtures.allSatisfy({ held in
            trainingFixtures.allSatisfy { train in
                !held.starts(with: train) && !train.starts(with: held)
            }
        }) else {
            throw HarnessError.overlappingTasks
        }
        let names = (training + heldOut).map(\.name)
        guard Set(names).count == names.count else { throw HarnessError.duplicateTaskNames }
        guard maxModelCalls > 0 else { throw HarnessError.budgetExceeded }
        let currentGeneration = generation
        let executor = self.executor
        let worker = Task {
            try await Self.evaluate(baseline: baseline, training: training, heldOut: heldOut, route: route, budget: maxModelCalls, executor: executor)
        }
        running = worker
        defer { running = nil }
        let report = try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
        try Task.checkCancellation()
        guard enabled, generation == currentGeneration else { throw CancellationError() }
        if report.accepted {
            let data = try JSONEncoder().encode(report.candidate)
            try FileManager.default.createDirectory(at: profileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: profileURL, options: .atomic)
        }
        return report
    }

    private static func evaluate(
        baseline: HarnessProfile, training: [HarnessTask], heldOut: [HarnessTask],
        route: HarnessRoute, budget: Int, executor: any HarnessExecutor
    ) async throws -> HarnessReport {
        var remaining = budget
        var evidence: [HarnessEvidence] = []
        for task in training {
            try Task.checkCancellation()
            let verified = try await isolatedRun(task: task, profile: baseline, route: route, remaining: remaining, executor: executor)
            try debit(verified.run, route: route, remaining: &remaining)
            evidence.append(HarnessEvidence(task: task.name, trace: verified.run.trace, verificationPassed: verified.passed))
        }
        try Task.checkCancellation()
        guard remaining > 0 else { throw HarnessError.budgetExceeded }
        let proposal = try await executor.propose(baseline: baseline, evidence: evidence, route: route, maxModelCalls: remaining)
        try debit(proposal.run, route: route, remaining: &remaining)
        guard proposal.profile.instructions != baseline.instructions else { throw HarnessError.noImprovement }

        var comparisons: [HarnessComparison] = []
        for (index, task) in heldOut.enumerated() {
            try Task.checkCancellation()
            // Each comparison must give both profiles the same call allowance.
            // Reserve a share for every remaining pair and redistribute unused calls
            // only between pairs, never from one profile to its competitor.
            let perRun = remaining / (2 * (heldOut.count - index))
            guard perRun > 0 else { throw HarnessError.budgetExceeded }
            // Freeze the held-out input once: a project change between the two
            // runs must not give one profile a different starting workspace.
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: task.fixture.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw HarnessError.invalidFixture
            }
            let frozen = FileManager.default.temporaryDirectory.appendingPathComponent("commondev-harness-pair-" + UUID().uuidString, isDirectory: true)
            try HarnessProjectSnapshot.copy(from: task.fixture, to: frozen)
            defer { try? FileManager.default.removeItem(at: frozen) }
            let fixedTask = HarnessTask(name: task.name, prompt: task.prompt, fixture: frozen)
            let original = try await isolatedRun(task: fixedTask, profile: baseline, route: route, remaining: perRun, executor: executor)
            guard original.run.modelCalls <= perRun else { throw HarnessError.budgetExceeded }
            try debit(original.run, route: route, remaining: &remaining)
            let changed = try await isolatedRun(task: fixedTask, profile: proposal.profile, route: route, remaining: perRun, executor: executor)
            guard changed.run.modelCalls <= perRun else { throw HarnessError.budgetExceeded }
            try debit(changed.run, route: route, remaining: &remaining)
            comparisons.append(HarnessComparison(task: task.name, baselinePassed: original.passed, candidatePassed: changed.passed))
        }
        let improved = comparisons.contains { !$0.baselinePassed && $0.candidatePassed }
        let regressed = comparisons.contains { $0.baselinePassed && !$0.candidatePassed }
        return HarnessReport(candidate: proposal.profile, comparisons: comparisons, accepted: improved && !regressed, modelCalls: budget - remaining)
    }

    private static func debit(_ run: HarnessRun, route: HarnessRoute, remaining: inout Int) throws {
        guard run.route == route else { throw HarnessError.routeChanged }
        guard run.modelCalls > 0 else { throw HarnessError.invalidUsage }
        guard run.modelCalls <= remaining else { throw HarnessError.budgetExceeded }
        remaining -= run.modelCalls
    }

    private struct VerifiedRun {
        let run: HarnessRun
        let passed: Bool
    }

    private static func isolatedRun(
        task: HarnessTask, profile: HarnessProfile, route: HarnessRoute,
        remaining: Int, executor: any HarnessExecutor
    ) async throws -> VerifiedRun {
        guard remaining > 0 else { throw HarnessError.budgetExceeded }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: task.fixture.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw HarnessError.invalidFixture
        }
        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent("commondev-harness-" + UUID().uuidString, isDirectory: true)
        try HarnessProjectSnapshot.copy(from: task.fixture, to: workspace)
        defer { try? FileManager.default.removeItem(at: workspace) }
        try Task.checkCancellation()
        let run = try await executor.run(task: task, workspace: workspace, profile: profile, route: route, maxModelCalls: remaining)
        try Task.checkCancellation()
        let passed = try await executor.verify(task: task, workspace: workspace)
        try Task.checkCancellation()
        return VerifiedRun(run: run, passed: passed)
    }
}

