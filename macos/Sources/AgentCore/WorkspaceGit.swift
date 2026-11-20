import Foundation

/// Fixed read-only Git commands, restricted to the selected project directory.
enum WorkspaceGit {
    static func diff(workspace: URL) async throws -> String {
        let staged = try await run("diff --cached --no-ext-diff --no-textconv -- .", workspace: workspace)
        guard staged.exitCode == 0 else { return failure(staged) }
        let unstaged = try await run("diff --no-ext-diff --no-textconv -- .", workspace: workspace)
        guard unstaged.exitCode == 0 else { return failure(unstaged) }
        let untracked = try await run("ls-files --others --exclude-standard -- .", workspace: workspace)
        guard untracked.exitCode == 0 else { return failure(untracked) }
        return "Подготовленные изменения:\n\(display(staged.output))\n\nНеподготовленные изменения:\n\(display(unstaged.output))\n\nНеотслеживаемые файлы:\n\(display(untracked.output))"
    }

    static func history(workspace: URL) async throws -> String {
        let result = try await run("-c log.showSignature=false log -n 30 --format='%h %cs %s' -- .", workspace: workspace)
        guard result.exitCode == 0 else { return failure(result) }
        return display(result.output)
    }

    private static func run(_ arguments: String, workspace: URL) async throws -> CommandResult {
        // Arguments are fixed by this implementation; no model text enters the shell.
        try await CommandRunner.runResult("GIT_OPTIONAL_LOCKS=0 /usr/bin/git --no-pager \(arguments)", cwd: workspace)
    }

    private static func display(_ output: String) -> String {
        guard !output.isEmpty else { return "Нет." }
        return output + (output.utf8.count >= 199_997 ? "\nВывод ограничен." : "")
    }

    private static func failure(_ result: CommandResult) -> String {
        "Не удалось прочитать Git (код \(result.exitCode)):\n\(display(result.output))"
    }
}
