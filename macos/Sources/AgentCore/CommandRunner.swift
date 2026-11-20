import Darwin
import Foundation

public struct CommandResult: Sendable {
    public let output: String
    public let exitCode: Int32
}

/// Runs each shell command in a separate process group so cancellation reaches its children.
public enum CommandRunner {
    static func run(_ command: String, cwd: URL) async throws -> String {
        let result = try await runResult(command, cwd: cwd)
        return result.output + "\nКод завершения: \(result.exitCode)"
    }

    public static func runResult(_ command: String, cwd: URL) async throws -> CommandResult {
        try await runResult(executable: "/bin/sh", arguments: ["-c", command], cwd: cwd)
    }

    public static func runResult(executable: String, arguments: [String], cwd: URL) async throws -> CommandResult {
        try Task.checkCancellation()
        // Drain output continuously, but retain only a bounded prefix. An output
        // file could otherwise fill the disk before a command exits.
        var descriptors: [Int32] = [-1, -1]
        guard pipe(&descriptors) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let reader = descriptors[0], writer = descriptors[1]
        defer { close(reader) }
        var writerOpen = true
        defer { if writerOpen { close(writer) } }
        guard fcntl(reader, F_SETFL, O_NONBLOCK) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard fcntl(reader, F_SETFD, FD_CLOEXEC) == 0, fcntl(writer, F_SETFD, FD_CLOEXEC) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        try check(posix_spawn_file_actions_init(&actions))
        defer { posix_spawn_file_actions_destroy(&actions) }
        try check(posix_spawnattr_init(&attributes))
        defer { posix_spawnattr_destroy(&attributes) }
        try check(posix_spawn_file_actions_adddup2(&actions, writer, STDOUT_FILENO))
        try check(posix_spawn_file_actions_adddup2(&actions, writer, STDERR_FILENO))
        try check(posix_spawn_file_actions_addclose(&actions, reader))
        try check(posix_spawn_file_actions_addclose(&actions, writer))
        try check(posix_spawn_file_actions_addchdir_np(&actions, cwd.path))
        try check(posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP)))
        try check(posix_spawnattr_setpgroup(&attributes, 0))

        let args = ([executable] + arguments).map { strdup($0) }
        defer { args.forEach { free($0) } }
        var argv = args + [nil]
        let environment = ProcessInfo.processInfo.environment.map { strdup("\($0.key)=\($0.value)") }
        defer { environment.forEach { free($0) } }
        var envp = environment + [nil]
        var pid: pid_t = 0
        try check(posix_spawn(&pid, executable, &actions, &attributes, &argv, &envp))
        close(writer)
        writerOpen = false
        let outputLimit = 200_000
        var output = Data()
        var truncated = false
        func drain() throws -> Bool {
            var buffer = [UInt8](repeating: 0, count: 16_384)
            var received = false
            // Keep cancellation responsive even if the writer never pauses.
            for _ in 0..<16 {
                let count = read(reader, &buffer, buffer.count)
                if count > 0 {
                    received = true
                    let retained = min(Int(count), outputLimit - output.count)
                    if retained > 0 { output.append(contentsOf: buffer.prefix(retained)) }
                    if retained < count { truncated = true }
                } else if count == 0 || errno == EAGAIN || errno == EWOULDBLOCK {
                    return received
                } else if errno != EINTR {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
            }
            return received
        }
        var status: Int32 = 0
        while true {
            let received = try drain()
            let waited = waitpid(pid, &status, WNOHANG)
            if waited == pid {
                // At most a pipe buffer remains after the process exits.
                _ = try drain()
                break
            }
            if waited < 0 {
                if errno == EINTR { continue }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            do {
                try await Task.sleep(nanoseconds: received ? 1_000_000 : 100_000_000)
            } catch {
                // Send to the process group before reaping its leader, and do not let
                // descendants continue changing files after the user presses Stop.
                kill(-pid, SIGTERM)
                try? await Task.sleep(nanoseconds: 200_000_000)
                kill(-pid, SIGKILL)
                while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
                throw error
            }
        }
        let exitCode = (status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
        return CommandResult(output: String(decoding: output, as: UTF8.self) + (truncated ? "\nВывод ограничен." : ""), exitCode: exitCode)
    }

    private static func check(_ code: Int32) throws {
        guard code == 0 else { throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO) }
    }
}
