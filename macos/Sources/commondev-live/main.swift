import AgentCore
import Foundation
import Gateway

@main
struct CommondevLive {
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard arguments.count == 3 else {
            fputs("Usage: commondev-live <gateway-directory> <project-directory> <task>\n", stderr)
            exit(2)
        }

        let resources = URL(fileURLWithPath: arguments[0], isDirectory: true).standardizedFileURL
        let workspace = URL(fileURLWithPath: arguments[1], isDirectory: true).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: workspace.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            fputs("Project directory does not exist: \(workspace.path)\n", stderr)
            exit(2)
        }

        let dataDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("commondev-live-" + UUID().uuidString, isDirectory: true)
        let gateway = EmbeddedGateway(resourcesDirectory: resources, dataDirectory: dataDirectory)
        var exitCode: Int32 = 0
        do {
            print("Preparing free models...")
            fflush(stdout)
            let connection = try await gateway.start()
            let client = OpenAICompatibleClient(
                endpoint: connection.endpoint, model: "auto:fast", apiKey: connection.apiKey
            )
            let agent = LiveAgent(
                workspace: workspace,
                client: client,
                onEvent: { event in
                    switch event {
                    case .notice(let text):
                        print("\n\(text)")
                    case .text(let text):
                        print(text, terminator: "")
                        fflush(stdout)
                    case .toolStarted(let id, let description):
                        print("\n[\(id)] Starting: \(description)")
                    case .toolFinished(let id, let result):
                        print("[\(id)] Result: \(result)")
                    case .route(let route):
                        print("\nRoute: \(route)")
                    case .modelRequest, .modelIdentity, .conversation:
                        break
                    }
                },
                approve: { request in
                    switch request {
                    case .command(let command, let cwd):
                        print("\nCommand in \(cwd):\n\(command)")
                    case .edit(let path, let diff):
                        print("\nProposed edit to \(path):\n\(diff)")
                    }
                    print("Allow? [y/N] ", terminator: "")
                    fflush(stdout)
                    guard let answer = readLine() else { return false }
                    return ["y", "yes", "д", "да"].contains(
                        answer.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    )
                }
            )
            _ = try await agent.run(task: arguments[2])
            print()
        } catch {
            fputs("\nLive agent failed: \(error.localizedDescription)\n", stderr)
            exitCode = 1
        }
        await gateway.stop()
        try? FileManager.default.removeItem(at: dataDirectory)
        exit(exitCode)
    }
}
