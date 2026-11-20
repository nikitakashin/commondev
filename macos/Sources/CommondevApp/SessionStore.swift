import Foundation

/// The index is committed after the session files, including on the first save
/// of an older installation whose sessions.json contains complete sessions.
final class SessionStore {
    private struct Index: Codable, Equatable {
        let sessionIDs: [UUID]
        var lastProjectPath: String?
    }

    let indexURL: URL
    private let directory: URL
    private var index: Index?
    private(set) var lastProjectPath: String?

    init(root: URL) {
        indexURL = root.appendingPathComponent("sessions.json")
        directory = root.appendingPathComponent("Sessions", isDirectory: true)
    }

    private func file(_ id: UUID) -> URL {
        directory.appendingPathComponent(id.uuidString + ".json")
    }

    func load() throws -> [ChatSession] {
        let data: Data
        do { data = try Data(contentsOf: indexURL) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return [] }
        let decoder = JSONDecoder()
        if let index = try? decoder.decode(Index.self, from: data) {
            let sessions = try index.sessionIDs.map { id in
                let session = try decoder.decode(ChatSession.self, from: Data(contentsOf: file(id)))
                guard session.id == id else { throw CocoaError(.fileReadCorruptFile) }
                return session
            }
            guard Set(index.sessionIDs).count == sessions.count else { throw CocoaError(.fileReadCorruptFile) }
            self.index = index
            lastProjectPath = index.lastProjectPath
            return sessions
        }
        let legacy = try decoder.decode([ChatSession].self, from: data)
        guard Set(legacy.map(\.id)).count == legacy.count else { throw CocoaError(.fileReadCorruptFile) }
        return legacy
    }

    func rememberProject(_ path: String) throws {
        guard lastProjectPath != path else { return }
        if var updated = index {
            updated.lastProjectPath = path
            try writeIndex(updated)
        }
        lastProjectPath = path
    }

    func save(_ sessions: [ChatSession], changed id: UUID?) throws {
        let encoder = JSONEncoder()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let ids = sessions.map(\.id)
        let previouslySaved = Set(index?.sessionIDs ?? [])
        for session in sessions where session.id == id || !previouslySaved.contains(session.id) {
            try encoder.encode(session).write(to: file(session.id), options: .atomic)
        }
        let updated = Index(sessionIDs: ids, lastProjectPath: lastProjectPath)
        if index != updated { try writeIndex(updated) }
    }

    func remove(_ id: UUID, remaining sessions: [ChatSession]) throws -> Error? {
        // Keep the index readable if the app exits between removing the entry and its file.
        try save(sessions, changed: nil)
        do {
            try FileManager.default.removeItem(at: file(id))
            return nil
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            return nil
        } catch {
            return error
        }
    }

    private func writeIndex(_ index: Index) throws {
        try JSONEncoder().encode(index).write(to: indexURL, options: .atomic)
        self.index = index
    }
}
