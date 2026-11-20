import AgentCore
import Foundation

struct ChatGit {
    let root: URL
    let branch: String?
    let branches: [String]
    let hasCommit: Bool

    static func inspect(_ project: URL) async throws -> ChatGit? {
        let root = try await run(["rev-parse", "--show-toplevel"], in: project)
        guard root.exitCode == 0 else { return nil }
        let rootURL = URL(fileURLWithPath: value(root), isDirectory: true).resolvingSymlinksInPath()
        let branch = try await run(["symbolic-ref", "--quiet", "--short", "HEAD"], in: rootURL)
        let commit = try await run(["rev-parse", "--verify", "HEAD"], in: rootURL)
        let refs = try await run(["for-each-ref", "--format=%(refname:lstrip=2)", "refs/heads/"], in: rootURL)
        return ChatGit(root: rootURL, branch: branch.exitCode == 0 ? value(branch) : nil,
                       branches: refs.exitCode == 0 ? refs.output.split(whereSeparator: \.isNewline).map(String.init) : [],
                       hasCommit: commit.exitCode == 0)
    }

    static func createWorktree(for project: URL, branch: String?, at destination: URL) async throws -> URL {
        guard let repository = try await inspect(project) else {
            throw Failure(message: "В выбранной папке нет Git-репозитория.")
        }
        let source = branch.map { "refs/heads/\($0)" } ?? "HEAD"
        let revision = try await run(["rev-parse", "--verify", "--end-of-options", source + "^{commit}"], in: repository.root)
        guard revision.exitCode == 0 else { throw Failure(message: "Ветка или коммит недоступны: \(source).") }
        let commit = value(revision)
        let sourcePath = project.resolvingSymlinksInPath().path
        var relative = ""
        if sourcePath != repository.root.path {
            let prefix = repository.root.path.hasSuffix("/") ? repository.root.path : repository.root.path + "/"
            guard sourcePath.hasPrefix(prefix) else { throw Failure(message: "Папка находится вне Git-репозитория.") }
            relative = String(sourcePath.dropFirst(prefix.count))
            let subtree = try await run(["cat-file", "-t", "\(commit):\(relative)"], in: repository.root)
            guard subtree.exitCode == 0, value(subtree) == "tree" else {
                throw Failure(message: "Этой папки нет в выбранной ветке.")
            }
        }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let result = try await run(["-c", "core.hooksPath=/dev/null", "worktree", "add", "--detach", "--", destination.path, commit],
                                   in: repository.root)
        guard result.exitCode == 0 else { throw Failure(message: value(result)) }
        return relative.isEmpty ? destination : destination.appendingPathComponent(relative, isDirectory: true)
    }

    private static func run(_ args: [String], in directory: URL) async throws -> CommandResult {
        try await CommandRunner.runResult(executable: "/usr/bin/git", arguments: ["--no-pager"] + args, cwd: directory)
    }

    private static func value(_ result: CommandResult) -> String { result.output.trimmingCharacters(in: .newlines) }

    private struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
}
