import AppKit
import AgentCore
import CryptoKit
import Foundation
import HarnessCore
import HarnessIntegration

/// Controls a user-configured real evaluation. The caller owns approval UI.
@MainActor
final class HarnessSupport: ObservableObject {
    @Published private(set) var enabled = false
    @Published var trainingPath = "" { didSet { saveSettings() } }
    @Published var heldOutPath = "" { didSet { saveSettings() } }
    @Published var prompt = "" { didSet { saveSettings() } }
    @Published var heldOutPrompt = "" { didSet { saveSettings() } }
    @Published var verificationCommand = "" { didSet { saveSettings() } }
    @Published var heldOutVerificationCommand = "" { didSet { saveSettings() } }
    @Published var actualModel = "" { didSet { saveSettings() } }
    @Published var expectedRoute = "" { didSet { saveSettings() } }
    @Published private(set) var status = ""
    @Published private(set) var isRunning = false

    private var coordinator: HarnessCoordinator?
    private var experiment: Task<Void, Never>?
    private var loadedProject: URL?
    private var loading = false
    private var generation = 0
    private var trackedRoute: HarnessRoute?
    private var routeTrackingInvalid = false
    private let standard = HarnessProfile(instructions: "Изучи задачу, внеси минимальное исправление и проверь результат.")
    private let storageRoot: URL

    init(storageRoot: URL? = nil) {
        self.storageRoot = storageRoot ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("commondev", isDirectory: true)
    }

    private struct Settings: Codable {
        var enabled: Bool?
        var trainingPath = ""
        var heldOutPath = ""
        var prompt = ""
        var heldOutPrompt: String?
        var verificationCommand = ""
        var heldOutVerificationCommand: String?
        var actualModel = ""
        var expectedRoute = ""
    }

    private struct Sample: Codable {
        let snapshot: String
        let prompt: String
        let testCommand: String
    }

    /// Capture the project before the user task starts. Only completed tasks
    /// with a successful approved test command are retained.
    func captureBefore(project: URL) async throws -> URL? {
        guard enabled, !isRunning else { return nil }
        let destination = casesDirectory(project: project).appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let worker = Task.detached {
            try HarnessProjectSnapshot.copy(from: project, to: destination)
        }
        try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
        if Task.isCancelled {
            try? FileManager.default.removeItem(at: destination)
            throw CancellationError()
        }
        return destination
    }

    func discardSample(snapshot: URL?, project: URL) {
        guard let snapshot, snapshot.deletingLastPathComponent().standardizedFileURL == casesDirectory(project: project).standardizedFileURL else { return }
        try? FileManager.default.removeItem(at: snapshot)
    }

    func recordCompletedSample(snapshot: URL?, project: URL, prompt: String, testCommand: String) {
        guard let snapshot, enabled,
              snapshot.deletingLastPathComponent().standardizedFileURL == casesDirectory(project: project).standardizedFileURL else { return }
        let command = testCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        let supportedCommands = ["swift test", "npm test", "npm run test", "pytest", "python -m pytest", "python3 -m pytest", "cargo test"]
        guard supportedCommands.contains(command), !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            discardSample(snapshot: snapshot, project: project)
            status = "Для Harness² нужна подтверждённая команда проверки с успешным результатом."
            return
        }
        let listURL = casesDirectory(project: project).appendingPathComponent("samples.json")
        do {
            var samples = FileManager.default.fileExists(atPath: listURL.path)
                ? try JSONDecoder().decode([Sample].self, from: Data(contentsOf: listURL)) : []
            samples.append(Sample(snapshot: snapshot.path, prompt: prompt, testCommand: command))
            let removed = samples.count > 2 ? Array(samples.dropLast(2)) : []
            samples = Array(samples.suffix(2))
            try JSONEncoder().encode(samples).write(to: listURL, options: .atomic)
            for sample in removed { discardSample(snapshot: URL(fileURLWithPath: sample.snapshot), project: project) }
            guard samples.count == 2 else {
                status = "Harness² собирает задачи для проверки: 1 из 2."
                return
            }
            trainingPath = samples[0].snapshot
            self.prompt = samples[0].prompt
            verificationCommand = samples[0].testCommand
            heldOutPath = samples[1].snapshot
            heldOutPrompt = samples[1].prompt
            heldOutVerificationCommand = samples[1].testCommand
            status = "Собраны две задачи для проверки Harness²."
        } catch {
            discardSample(snapshot: snapshot, project: project)
            status = "Не удалось сохранить пример для Harness²: " + error.localizedDescription
        }
    }

    func load(project: URL?) {
        let project = project?.standardizedFileURL.resolvingSymlinksInPath()
        guard loadedProject != project else { return }
        updateEnabled(false, persist: false)
        loadedProject = project
        loading = true
        defer { loading = false }
        let settings: Settings
        do {
            if let project {
                let url = settingsURL(project: project)
                settings = FileManager.default.fileExists(atPath: url.path)
                    ? try JSONDecoder().decode(Settings.self, from: Data(contentsOf: url))
                    : Settings()
            } else {
                settings = Settings()
            }
        } catch {
            settings = Settings()
            status = "Не удалось прочитать настройки Harness²: " + error.localizedDescription
        }
        trainingPath = settings.trainingPath
        heldOutPath = settings.heldOutPath
        prompt = settings.prompt
        heldOutPrompt = settings.heldOutPrompt ?? settings.prompt
        verificationCommand = settings.verificationCommand
        heldOutVerificationCommand = settings.heldOutVerificationCommand ?? settings.verificationCommand
        actualModel = settings.actualModel
        expectedRoute = settings.expectedRoute
        updateEnabled(settings.enabled ?? false, persist: false)
    }

    private func saveSettings() {
        guard !loading, let project = loadedProject else { return }
        let settings = Settings(enabled: enabled, trainingPath: trainingPath, heldOutPath: heldOutPath, prompt: prompt, heldOutPrompt: heldOutPrompt,
                                verificationCommand: verificationCommand, heldOutVerificationCommand: heldOutVerificationCommand,
                                actualModel: actualModel, expectedRoute: expectedRoute)
        let url = settingsURL(project: project)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(settings).write(to: url, options: .atomic)
        } catch {
            status = "Не удалось сохранить настройки Harness²: " + error.localizedDescription
        }
    }

    func setEnabled(_ enabled: Bool) {
        updateEnabled(enabled, persist: true)
    }

    private func updateEnabled(_ enabled: Bool, persist: Bool) {
        self.enabled = enabled
        if !enabled {
            generation += 1
            experiment?.cancel()
            let coordinator = self.coordinator
            Task { await coordinator?.setEnabled(false) }
            status = "Harness² выключен."
        } else {
            status = "Harness² включён. Собираем задачи с успешными проверками."
        }
        if persist { saveSettings() }
    }

    func activeInstructions(project: URL) throws -> String? {
        guard enabled else { return nil }
        let url = profileURL(project: project)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(HarnessProfile.self, from: Data(contentsOf: url)).instructions
    }

    /// A new user request must establish its own actual model/provider. Reusing
    /// an identity from a prior request can make experiments run on a model
    /// unrelated to the task from which the samples were collected.
    func beginRouteTracking() {
        trackedRoute = nil
        routeTrackingInvalid = false
        actualModel = ""
        expectedRoute = ""
    }

    /// Do not start an experiment if an identity is missing or changes during
    /// a single user request. Once invalid, only a new request can reset it.
    func observeRoute(model: String?, provider: String?) {
        guard !routeTrackingInvalid else { return }
        guard let model, !model.isEmpty, let provider, !provider.isEmpty else {
            routeTrackingInvalid = true
            actualModel = ""
            expectedRoute = ""
            return
        }
        let route = HarnessRoute(provider: provider, model: model)
        guard trackedRoute == nil || trackedRoute == route else {
            routeTrackingInvalid = true
            actualModel = ""
            expectedRoute = ""
            return
        }
        trackedRoute = route
        actualModel = model
        expectedRoute = provider
    }

    func start(project: URL, client: OpenAICompatibleClient, approve: @escaping @Sendable (ApprovalRequest) async -> Bool) {
        guard enabled, !isRunning else { return }
        guard !trainingPath.isEmpty, !heldOutPath.isEmpty, !prompt.isEmpty,
              !verificationCommand.isEmpty, !actualModel.isEmpty, !expectedRoute.isEmpty else {
            status = "Harness² ждёт две задачи с успешными проверками и подтверждённый маршрут модели."
            return
        }
        let train = HarnessTask(name: "training", prompt: prompt, fixture: URL(fileURLWithPath: trainingPath, isDirectory: true))
        let held = HarnessTask(name: "held-out", prompt: heldOutPrompt.isEmpty ? prompt : heldOutPrompt, fixture: URL(fileURLWithPath: heldOutPath, isDirectory: true))
        let heldCommand = heldOutVerificationCommand.isEmpty ? verificationCommand : heldOutVerificationCommand
        let executor = LiveHarnessExecutor(client: client.selectingModel(actualModel), verificationCommands: ["training": verificationCommand, "held-out": heldCommand], approve: approve)
        let coordinator = HarnessCoordinator(profileURL: profileURL(project: project), executor: executor)
        self.coordinator = coordinator
        let route = HarnessRoute(provider: expectedRoute, model: actualModel)
        let currentGeneration = generation
        isRunning = true
        status = "Идёт эксперимент. Разрешайте действия на копиях проектов."
        experiment = Task {
            defer { isRunning = false; experiment = nil }
            do {
                await coordinator.setEnabled(true)
                let baseline = try await coordinator.activeProfile(standard: standard)
                let report = try await coordinator.experiment(baseline: baseline, training: [train], heldOut: [held], route: route, maxModelCalls: 24)
                guard !Task.isCancelled, enabled, generation == currentGeneration else { return }
                status = report.accepted ? "Проверка пройдена, новый профиль сохранён." : "Улучшение не доказано, профиль сохранён прежним."
            } catch is CancellationError {
                if generation == currentGeneration { status = "Эксперимент остановлен." }
            } catch {
                if generation == currentGeneration { status = "Эксперимент остановлен: " + error.localizedDescription }
            }
        }
    }

    func stop() {
        experiment?.cancel()
        status = "Останавливаем эксперимент…"
    }

    private func profileURL(project: URL) -> URL {
        let path = project.standardizedFileURL.resolvingSymlinksInPath().path
        let digest = SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined()
        return storageRoot.appendingPathComponent("harness", isDirectory: true)
            .appendingPathComponent(digest + ".json")
    }

    private func settingsURL(project: URL) -> URL {
        profileURL(project: project).deletingPathExtension().appendingPathExtension("settings.json")
    }

    private func casesDirectory(project: URL) -> URL {
        profileURL(project: project).deletingPathExtension().appendingPathExtension("cases")
    }
}

