import Darwin
import Foundation

public struct GatewayConnection: Sendable {
    public let endpoint: URL
    public let apiKey: String

    public func availableModels(session: URLSession = .shared) async throws -> [GatewayModel] {
        let modelsURL = endpoint.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("models")
        var request = URLRequest(url: modelsURL.appending(queryItems: [.init(name: "execution_status", value: "ready")]),
                                 timeoutInterval: 10)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return try GatewayModel.ready(from: data)
    }
}

public struct GatewayModel: Decodable, Identifiable, Sendable {
    public let id: String
    public let name: String
    private let available: Bool
    private let supported_parameters: [String]?

    static func ready(from data: Data) throws -> [GatewayModel] {
        struct Catalog: Decodable { let data: [GatewayModel] }
        var seen = Set<String>()
        return try JSONDecoder().decode(Catalog.self, from: data).data
            .filter { $0.available && $0.supported_parameters?.contains("tools") == true && seen.insert($0.id).inserted }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

public enum GatewayError: LocalizedError {
    case missingResources
    case failedToStart
    case invalidHandshake
    case alreadyRunning
    case initialization(String)

    public var errorDescription: String? {
        switch self {
        case .missingResources: return "Компоненты FreeLLMAPI отсутствуют в приложении."
        case .failedToStart: return "Не удалось запустить FreeLLMAPI. Проверьте журнал шлюза."
        case .invalidHandshake: return "FreeLLMAPI вернул некорректное сообщение готовности."
        case .alreadyRunning: return "Другой экземпляр commondev уже использует бесплатные модели. Закройте его и повторите попытку."
        case .initialization(let message): return message
        }
    }
}

/// Owns the local gateway process and its private control pipes.
public actor EmbeddedGateway {
    private let resourcesDirectory: URL
    private let dataDirectory: URL
    private var process: Process?
    private var input: Pipe?
    private var connection: GatewayConnection?
    private var starting: Task<GatewayConnection, Error>?
    private var waiters: [UUID: CheckedContinuation<GatewayConnection, Error>] = [:]
    private var lockDescriptor: Int32 = -1
    private var retiring: (id: UUID, task: Task<Void, Never>)?
    private var stopGeneration: UInt64 = 0

    public init(resourcesDirectory: URL, dataDirectory: URL) {
        self.resourcesDirectory = resourcesDirectory
        self.dataDirectory = dataDirectory
    }

    public func start() async throws -> GatewayConnection {
        try Task.checkCancellation()
        let generation = stopGeneration
        if let retiring {
            await retiring.task.value
            try Task.checkCancellation()
            guard generation == stopGeneration else { throw CancellationError() }
            if self.retiring?.id == retiring.id { self.retiring = nil }
        }
        if let process, process.isRunning, let connection {
            return connection
        }
        if let process, !process.isRunning, starting == nil { releaseProcess() }
        if starting == nil { try beginStarting() }
        let waiter = UUID()
        let result = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiters[waiter] = continuation
                if Task.isCancelled { cancelWaiter(waiter) }
            }
        } onCancel: {
            Task { await self.cancelWaiter(waiter) }
        }
        try Task.checkCancellation()
        return result
    }

    private func beginStarting() throws {
        let node = resourcesDirectory.appendingPathComponent("node")
        let entry = resourcesDirectory.appendingPathComponent("gateway-entry.mjs")
        guard FileManager.default.isExecutableFile(atPath: node.path),
              FileManager.default.fileExists(atPath: entry.path),
              FileManager.default.fileExists(atPath: resourcesDirectory.appendingPathComponent("server.mjs").path)
        else { throw GatewayError.missingResources }

        try FileManager.default.createDirectory(
            at: dataDirectory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        // Only one gateway may use this database. Without an inter-process lock,
        // a second app instance can hang while the first owns SQLite state.
        let lockPath = dataDirectory.appendingPathComponent("gateway.lock").path
        let descriptor = open(lockPath, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            close(descriptor)
            if code == EWOULDBLOCK || code == EAGAIN { throw GatewayError.alreadyRunning }
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        var lockTransferred = false
        defer { if !lockTransferred { close(descriptor) } }
        let log = dataDirectory.appendingPathComponent("gateway.log")
        if !FileManager.default.fileExists(atPath: log.path) {
            _ = FileManager.default.createFile(atPath: log.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        let logHandle = try FileHandle(forWritingTo: log)
        try logHandle.seekToEnd()

        let process = Process()
        let output = Pipe()
        let input = Pipe()
        process.executableURL = node
        process.arguments = [entry.path, dataDirectory.path]
        process.currentDirectoryURL = resourcesDirectory
        process.standardInput = input
        process.standardOutput = output
        process.standardError = logHandle
        try process.run()
        self.process = process
        self.input = input
        lockDescriptor = descriptor
        lockTransferred = true

        let task = Task.detached {
            let handle = output.fileHandleForReading
            let fd = handle.fileDescriptor
            let flags = fcntl(fd, F_GETFL)
            guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else {
                throw GatewayError.failedToStart
            }
            let deadline = Date().addingTimeInterval(75)
            var data = Data()
            while data.count < 8192 {
                try Task.checkCancellation()
                guard Date() < deadline else { throw GatewayError.failedToStart }
                var byte: UInt8 = 0
                let count = read(fd, &byte, 1)
                if count == 0 {
                    throw GatewayError.failedToStart
                }
                if count < 0 {
                    guard errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR else {
                        throw GatewayError.failedToStart
                    }
                    try await Task.sleep(nanoseconds: 25_000_000)
                    continue
                }
                if byte == 10 { break }
                data.append(byte)
            }
            guard data.count < 8192,
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { throw GatewayError.invalidHandshake }
            if object["type"] as? String == "error" {
                throw GatewayError.initialization(object["message"] as? String ?? "Не удалось подготовить бесплатные модели.")
            }
            guard
                  object["type"] as? String == "ready",
                  let port = object["port"] as? Int, (1...65535).contains(port),
                  let token = object["token"] as? String, !token.isEmpty,
                  let endpoint = URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")
            else { throw GatewayError.invalidHandshake }
            return GatewayConnection(endpoint: endpoint, apiKey: token)
        }
        starting = task
        Task {
            let result = await task.result
            finishStarting(result, process: process)
        }
    }

    private func finishStarting(_ result: Result<GatewayConnection, Error>, process: Process) {
        guard self.process === process, starting != nil else { return }
        starting = nil
        let pending = Array(waiters.values)
        waiters.removeAll()
        switch result {
        case .success(let ready) where process.isRunning:
            connection = ready
            for waiter in pending { waiter.resume(returning: ready) }
        case .success:
            releaseProcess()
            for waiter in pending { waiter.resume(throwing: GatewayError.failedToStart) }
        case .failure(let error):
            releaseProcess()
            for waiter in pending { waiter.resume(throwing: error) }
        }
    }

    private func cancelWaiter(_ waiter: UUID) {
        guard let continuation = waiters.removeValue(forKey: waiter) else { return }
        continuation.resume(throwing: CancellationError())
        if waiters.isEmpty, starting != nil { stop() }
    }

    public func stop() {
        stopGeneration &+= 1
        starting?.cancel()
        starting = nil
        let pending = Array(waiters.values)
        waiters.removeAll()
        for waiter in pending { waiter.resume(throwing: CancellationError()) }
        connection = nil
        releaseProcess()
    }

    private func releaseProcess() {
        try? input?.fileHandleForWriting.close()
        input = nil
        let child = process
        process = nil
        let descriptor = lockDescriptor
        lockDescriptor = -1
        guard let child, child.isRunning else {
            if descriptor >= 0 { close(descriptor) }
            return
        }
        child.terminate()
        // Keep the lock until the old gateway has actually exited; a new
        // instance must not open its database during graceful shutdown.
        let retirement = Task.detached {
            for _ in 0..<20 {
                if !child.isRunning { break }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            if child.isRunning { kill(child.processIdentifier, SIGKILL) }
            child.waitUntilExit()
            if descriptor >= 0 { close(descriptor) }
        }
        retiring = (UUID(), retirement)
    }
}
