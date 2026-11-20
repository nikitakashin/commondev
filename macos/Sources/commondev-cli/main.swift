import AgentCore
import Foundation

func printUsage() {
    print("Usage: commondev-cli <project-directory>")
    print("Runs the deterministic test-repair demonstration in the given directory.")
}

func confirm(_ request: ApprovalRequest) -> Bool {
    switch request {
    case let .command(command, cwd):
        print("\nCommand in \(cwd):\n\(command)")
    case let .edit(path, diff):
        print("\nProposed edit to \(path):\n\(diff)")
    }

    print("Allow? [y/N] ", terminator: "")
    fflush(stdout)
    guard let answer = readLine() else {
        print("\nNo response; denied.")
        return false
    }
    return ["y", "yes", "д", "да"].contains(answer.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
}

func display(_ event: AgentEvent) {
    switch event {
    case let .toolStarted(id, description):
        print("\n[\(id)] Starting: \(description)")
    case let .toolFinished(id, result):
        print("[\(id)] Result: \(result)")
    case let .message(text):
        print(text)
    }
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count == 1, !["-h", "--help"].contains(arguments[0]) else {
    printUsage()
    exit(arguments.count == 1 ? 0 : 2)
}

let workspace = URL(fileURLWithPath: arguments[0], isDirectory: true).standardizedFileURL
var isDirectory: ObjCBool = false
guard FileManager.default.fileExists(atPath: workspace.path, isDirectory: &isDirectory),
      isDirectory.boolValue else {
    fputs("Project directory does not exist: \(workspace.path)\n", stderr)
    exit(2)
}

print("Deterministic demonstration for \(workspace.path)")
let agent = Agent(workspace: workspace, provider: TestProvider(), onEvent: display, approve: confirm)
do {
    let result = try agent.run(task: "Find and fix the failing test.")
    exit(result.success ? 0 : 1)
} catch {
    fputs("Agent failed: \(error)\n", stderr)
    exit(1)
}
