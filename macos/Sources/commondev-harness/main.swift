import Foundation
import AgentCore
import HarnessCore
import HarnessIntegration

@main
struct HarnessCommand {
    static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.count == 9, let endpoint = URL(string: args[0]),
              ["http", "https"].contains(endpoint.scheme ?? ""), endpoint.host != nil else {
            fputs("Usage: commondev-harness <chat-completions-url> <selected-model> <actual-model> <expected-route-header> <training-project> <held-out-project> <task-prompt> <test-command> <profile-file>\n", stderr)
            fputs("Uses the selected live model. Checks and agent actions ask for confirmation. COMMONDEV_API_KEY is optional.\n", stderr)
            exit(2)
        }
        let endpointClient = OpenAICompatibleClient(endpoint: endpoint, model: args[1], apiKey: ProcessInfo.processInfo.environment["COMMONDEV_API_KEY"])
        let executor = LiveHarnessExecutor(client: endpointClient, verificationCommands: ["training": args[7], "held-out": args[7]]) { request in
            switch request {
            case .command(let command, let cwd):
                print("\nCommand in " + cwd + ":\n" + command)
            case .edit(let path, let diff):
                print("\nEdit " + path + ":\n" + diff)
            }
            print("Allow? [y/N] ", terminator: "")
            fflush(stdout)
            return ["y", "yes", "д", "да"].contains((readLine() ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        }
        let coordinator = HarnessCoordinator(profileURL: URL(fileURLWithPath: args[8]), executor: executor)
        await coordinator.setEnabled(true)
        let standard = HarnessProfile(instructions: "Изучи задачу, внеси минимальное исправление и проверь результат.")
        let training = HarnessTask(name: "training", prompt: args[6], fixture: URL(fileURLWithPath: args[4], isDirectory: true))
        let heldOut = HarnessTask(name: "held-out", prompt: args[6], fixture: URL(fileURLWithPath: args[5], isDirectory: true))
        do {
            let baseline = try await coordinator.activeProfile(standard: standard)
            let report = try await coordinator.experiment(baseline: baseline, training: [training], heldOut: [heldOut], route: HarnessRoute(provider: args[3], model: args[2]), maxModelCalls: 24)
            print(report.accepted ? "Улучшение принято." : "Улучшение не доказано.")
            for comparison in report.comparisons {
                print("\(comparison.task): baseline=\(comparison.baselinePassed), candidate=\(comparison.candidatePassed)")
            }
            print("Запросы к модели: \(report.modelCalls)")
        } catch {
            fputs("Эксперимент остановлен: " + error.localizedDescription + "\n", stderr)
            exit(1)
        }
    }
}

