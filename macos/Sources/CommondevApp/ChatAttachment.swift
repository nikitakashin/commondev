import Darwin
import Foundation

struct ChatAttachment: Identifiable, Codable {
    static let maxCount = 4
    static let maxBytes = 12_000

    var id = UUID()
    var name: String
    var content: String

    init(file: URL) throws {
        let descriptor = open(file.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw CocoaError(.fileReadNoPermission) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size <= Self.maxBytes else { throw CocoaError(.fileReadTooLarge) }
        let data = try handle.read(upToCount: Self.maxBytes + 1) ?? Data()
        guard data.count <= Self.maxBytes, !data.contains(0),
              let text = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        name = file.lastPathComponent
        content = text
    }
}
