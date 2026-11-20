import Foundation
import XCTest
@testable import HarnessCore

final class HarnessCoordinatorTests: XCTestCase {
    private func fixtures() throws -> (URL, HarnessTask, HarnessTask) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let training = dir.appendingPathComponent("training")
        let heldout = dir.appendingPathComponent("heldout")
        try FileManager.default.createDirectory(at: training, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: heldout, withIntermediateDirectories: true)
        try "untouched".write(to: heldout.appendingPathComponent("input"), atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return (dir, HarnessTask(name: "train", prompt: "", fixture: training), HarnessTask(name: "held", prompt: "", fixture: heldout))
    }

    func testImprovementIsVerifiedAndDisabledModeUsesStandardProfile() async throws {
        let (dir, train, held) = try fixtures()
        let standard = HarnessProfile(instructions: "bad")
        let coordinator = HarnessCoordinator(profileURL: dir.appendingPathComponent("profile.json"), executor: TestExecutor())
        await coordinator.setEnabled(true)
        let report = try await coordinator.experiment(baseline: standard, training: [train], heldOut: [held], route: TestExecutor.route, maxModelCalls: 4)
        XCTAssertTrue(report.accepted)
        XCTAssertEqual(report.modelCalls, 4)
        let learned = try await coordinator.activeProfile(standard: standard)
        XCTAssertEqual(learned.instructions, "good")
        XCTAssertEqual(try String(contentsOf: held.fixture.appendingPathComponent("input"), encoding: .utf8), "untouched")
        XCTAssertFalse(FileManager.default.fileExists(atPath: held.fixture.appendingPathComponent("result").path))
        await coordinator.setEnabled(false)
        let active = try await coordinator.activeProfile(standard: standard)
        XCTAssertEqual(active, standard)
        await coordinator.setEnabled(true)
        let restored = try await coordinator.activeProfile(standard: standard)
        XCTAssertEqual(restored.instructions, "good")
    }

    func testRouteChangeRejectsCandidate() async throws {
        let (dir, train, held) = try fixtures()
        let coordinator = HarnessCoordinator(profileURL: dir.appendingPathComponent("profile.json"), executor: TestExecutor(changeRoute: true))
        await coordinator.setEnabled(true)
        do {
            _ = try await coordinator.experiment(baseline: HarnessProfile(instructions: "bad"), training: [train], heldOut: [held], route: TestExecutor.route, maxModelCalls: 4)
            XCTFail("A changed model must not be accepted")
        } catch HarnessError.routeChanged {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("profile.json").path))
    }

    func testRegressionIsNotAccepted() async throws {
        let (dir, train, held) = try fixtures()
        let coordinator = HarnessCoordinator(profileURL: dir.appendingPathComponent("profile.json"), executor: TestExecutor(candidate: "bad"))
        await coordinator.setEnabled(true)
        let report = try await coordinator.experiment(baseline: HarnessProfile(instructions: "good"), training: [train], heldOut: [held], route: TestExecutor.route, maxModelCalls: 4)
        XCTAssertFalse(report.accepted)
        XCTAssertTrue(report.comparisons[0].baselinePassed)
        XCTAssertFalse(report.comparisons[0].candidatePassed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("profile.json").path))
    }

    func testBudgetAndDistinctFixturesAreRequired() async throws {
        let (dir, train, held) = try fixtures()
        let coordinator = HarnessCoordinator(profileURL: dir.appendingPathComponent("profile.json"), executor: TestExecutor())
        await coordinator.setEnabled(true)
        do {
            _ = try await coordinator.experiment(baseline: HarnessProfile(instructions: "bad"), training: [train], heldOut: [train], route: TestExecutor.route, maxModelCalls: 4)
            XCTFail("Training fixture cannot be used as held-out")
        } catch HarnessError.overlappingTasks {}
        do {
            _ = try await coordinator.experiment(baseline: HarnessProfile(instructions: "bad"), training: [train], heldOut: [held], route: TestExecutor.route, maxModelCalls: 3)
            XCTFail("Budget insufficient")
        } catch HarnessError.budgetExceeded {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("profile.json").path))
    }

    func testDisabledCancelsExperimentWithoutSaving() async throws {
        let (dir, train, held) = try fixtures()
        let coordinator = HarnessCoordinator(profileURL: dir.appendingPathComponent("profile.json"), executor: TestExecutor(slow: true))
        await coordinator.setEnabled(true)
        let run = Task { try await coordinator.experiment(baseline: HarnessProfile(instructions: "bad"), training: [train], heldOut: [held], route: TestExecutor.route, maxModelCalls: 4) }
        try await Task.sleep(nanoseconds: 30_000_000)
        await coordinator.setEnabled(false)
        do { _ = try await run.value; XCTFail("Expected cancellation") } catch is CancellationError {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("profile.json").path))
    }

    func testNestedTrainingAndHeldOutFixturesAreRejectedInBothDirections() async throws {
        let (dir, train, _) = try fixtures()
        let nested = train.fixture.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let nestedTask = HarnessTask(name: "nested", prompt: "", fixture: nested)
        let coordinator = HarnessCoordinator(profileURL: dir.appendingPathComponent("profile.json"), executor: TestExecutor())
        await coordinator.setEnabled(true)
        for (training, heldOut) in [([train], [nestedTask]), ([nestedTask], [train])] {
            do {
                _ = try await coordinator.experiment(baseline: HarnessProfile(instructions: "bad"), training: training, heldOut: heldOut, route: TestExecutor.route, maxModelCalls: 4)
                XCTFail("Nested fixtures must never be compared")
            } catch HarnessError.overlappingTasks {}
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("profile.json").path))
    }

    func testSymlinkAliasesAreCheckedForNestedFixtures() async throws {
        let (dir, train, _) = try fixtures()
        let nested = train.fixture.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let alias = dir.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: nested)
        let coordinator = HarnessCoordinator(profileURL: dir.appendingPathComponent("profile.json"), executor: TestExecutor())
        await coordinator.setEnabled(true)
        do {
            _ = try await coordinator.experiment(baseline: HarnessProfile(instructions: "bad"), training: [train], heldOut: [HarnessTask(name: "nested", prompt: "", fixture: alias)], route: TestExecutor.route, maxModelCalls: 4)
            XCTFail("A symlink must not hide fixture overlap")
        } catch HarnessError.overlappingTasks {}
    }

    func testDistinctFixturesCannotShareAVerificationName() async throws {
        let (dir, train, held) = try fixtures()
        let coordinator = HarnessCoordinator(profileURL: dir.appendingPathComponent("profile.json"), executor: TestExecutor())
        await coordinator.setEnabled(true)
        let duplicate = HarnessTask(name: train.name, prompt: "", fixture: held.fixture)
        do {
            _ = try await coordinator.experiment(baseline: HarnessProfile(instructions: "bad"), training: [train], heldOut: [duplicate], route: TestExecutor.route, maxModelCalls: 4)
            XCTFail("Verification commands must not be ambiguous")
        } catch HarnessError.duplicateTaskNames {}
    }

    func testSiblingPathsWithCommonPrefixRemainDistinct() async throws {
        let (dir, train, _) = try fixtures()
        let sibling = dir.appendingPathComponent("training-copy")
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        let coordinator = HarnessCoordinator(profileURL: dir.appendingPathComponent("profile.json"), executor: TestExecutor())
        await coordinator.setEnabled(true)
        let report = try await coordinator.experiment(baseline: HarnessProfile(instructions: "bad"), training: [train], heldOut: [HarnessTask(name: "sibling", prompt: "", fixture: sibling)], route: TestExecutor.route, maxModelCalls: 4)
        XCTAssertTrue(report.accepted)
    }

    func testHeldOutProfilesReceiveEqualBudgets() async throws {
        let (dir, train, held) = try fixtures()
        let executor = BudgetRecordingExecutor()
        let coordinator = HarnessCoordinator(profileURL: dir.appendingPathComponent("profile.json"), executor: executor)
        await coordinator.setEnabled(true)
        let report = try await coordinator.experiment(baseline: HarnessProfile(instructions: "bad"), training: [train], heldOut: [held], route: TestExecutor.route, maxModelCalls: 10)
        let budgets = await executor.heldOutBudgets
        XCTAssertEqual(budgets, [4, 4])
        XCTAssertTrue(report.accepted)
        XCTAssertEqual(report.modelCalls, 7)
    }

    func testProposalReceivesIndependentTrainingVerificationResult() async throws {
        let (dir, train, held) = try fixtures()
        let executor = BudgetRecordingExecutor()
        let coordinator = HarnessCoordinator(profileURL: dir.appendingPathComponent("profile.json"), executor: executor)
        await coordinator.setEnabled(true)
        _ = try await coordinator.experiment(baseline: HarnessProfile(instructions: "bad"), training: [train], heldOut: [held], route: TestExecutor.route, maxModelCalls: 10)
        let failed = await executor.verificationResults
        XCTAssertEqual(failed, [false])
        _ = try await coordinator.experiment(baseline: HarnessProfile(instructions: "good"), training: [train], heldOut: [held], route: TestExecutor.route, maxModelCalls: 10)
        let passed = await executor.verificationResults
        XCTAssertEqual(passed, [true])
    }

    func testHeldOutPairUsesSameSnapshotIfOriginalChanges() async throws {
        let (dir, train, held) = try fixtures()
        let executor = ChangingFixtureExecutor(original: held.fixture)
        let coordinator = HarnessCoordinator(profileURL: dir.appendingPathComponent("profile.json"), executor: executor)
        await coordinator.setEnabled(true)
        _ = try await coordinator.experiment(baseline: HarnessProfile(instructions: "bad"), training: [train], heldOut: [held], route: TestExecutor.route, maxModelCalls: 4)
        let observed = await executor.observedInputs
        XCTAssertEqual(observed, ["untouched", "untouched"])
        XCTAssertEqual(try String(contentsOf: held.fixture.appendingPathComponent("input"), encoding: .utf8), "changed")
    }
}

private actor ChangingFixtureExecutor: HarnessExecutor {
    let original: URL
    private(set) var observedInputs: [String] = []
    init(original: URL) { self.original = original }

    func run(task: HarnessTask, workspace: URL, profile: HarnessProfile, route: HarnessRoute, maxModelCalls: Int) async throws -> HarnessRun {
        if task.name == "held" {
            observedInputs.append(try String(contentsOf: workspace.appendingPathComponent("input"), encoding: .utf8))
            if observedInputs.count == 1 {
                try "changed".write(to: original.appendingPathComponent("input"), atomically: true, encoding: .utf8)
            }
        }
        return HarnessRun(route: route, modelCalls: 1, trace: "done")
    }

    func propose(baseline: HarnessProfile, evidence: [HarnessEvidence], route: HarnessRoute, maxModelCalls: Int) async throws -> (profile: HarnessProfile, run: HarnessRun) {
        (HarnessProfile(instructions: "good"), HarnessRun(route: route, modelCalls: 1, trace: "proposed"))
    }

    func verify(task: HarnessTask, workspace: URL) async throws -> Bool { false }
}

private actor BudgetRecordingExecutor: HarnessExecutor {
    private(set) var heldOutBudgets: [Int] = []
    private(set) var verificationResults: [Bool] = []

    func run(task: HarnessTask, workspace: URL, profile: HarnessProfile, route: HarnessRoute, maxModelCalls: Int) async throws -> HarnessRun {
        let isHeldOut = task.name == "held"
        if isHeldOut { heldOutBudgets.append(maxModelCalls) }
        try profile.instructions.write(to: workspace.appendingPathComponent("result"), atomically: true, encoding: .utf8)
        return HarnessRun(route: route, modelCalls: isHeldOut && profile.instructions == "bad" ? maxModelCalls : 1, trace: "done")
    }

    func propose(baseline: HarnessProfile, evidence: [HarnessEvidence], route: HarnessRoute, maxModelCalls: Int) async throws -> (profile: HarnessProfile, run: HarnessRun) {
        verificationResults = evidence.map(\.verificationPassed)
        return (HarnessProfile(instructions: baseline.instructions == "good" ? "bad" : "good"), HarnessRun(route: route, modelCalls: 1, trace: "proposed"))
    }

    func verify(task: HarnessTask, workspace: URL) async throws -> Bool {
        try String(contentsOf: workspace.appendingPathComponent("result"), encoding: .utf8) == "good"
    }
}

private struct TestExecutor: HarnessExecutor {
    static let route = HarnessRoute(provider: "example", model: "fixed")
    var changeRoute = false
    var slow = false
    var candidate = "good"

    func run(task: HarnessTask, workspace: URL, profile: HarnessProfile, route: HarnessRoute, maxModelCalls: Int) async throws -> HarnessRun {
        if slow { try await Task.sleep(nanoseconds: 5_000_000_000) }
        try profile.instructions.write(to: workspace.appendingPathComponent("result"), atomically: true, encoding: .utf8)
        return HarnessRun(route: changeRoute ? HarnessRoute(provider: "different", model: "fixed") : route, modelCalls: 1, trace: "done")
    }

    func propose(baseline: HarnessProfile, evidence: [HarnessEvidence], route: HarnessRoute, maxModelCalls: Int) async throws -> (profile: HarnessProfile, run: HarnessRun) {
        (HarnessProfile(instructions: candidate), HarnessRun(route: route, modelCalls: 1, trace: "proposed"))
    }

    func verify(task: HarnessTask, workspace: URL) async throws -> Bool {
        try String(contentsOf: workspace.appendingPathComponent("result"), encoding: .utf8) == "good"
    }
}

