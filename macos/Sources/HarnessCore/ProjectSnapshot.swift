import Foundation

/// Creates a project snapshot without copying version-control and build caches.
/// Links must stay inside the copied project so runs cannot follow them into the
/// original workspace.
public enum HarnessProjectSnapshot {
    public static func copy(from source: URL, to destination: URL) throws {
        let root = source.standardizedFileURL.resolvingSymlinksInPath()
        let manager = FileManager.default
        var enumerationError: Error?
        guard let enumerator = manager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey],
            options: [],
            errorHandler: { _, error in
                enumerationError = error
                return false
            }
        ) else { throw HarnessError.invalidFixture }

        try manager.createDirectory(at: destination, withIntermediateDirectories: false)
        do {
            for case let item as URL in enumerator {
                try Task.checkCancellation()
                let path = item.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath()
                    .appendingPathComponent(item.lastPathComponent).path
                guard path.hasPrefix(root.path + "/") else { throw HarnessError.invalidFixture }
                let relative = String(path.dropFirst(root.path.count + 1))
                let target = destination.appendingPathComponent(relative)
                let values = try item.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
                if values.isSymbolicLink == true {
                    let link = try manager.destinationOfSymbolicLink(atPath: item.path)
                    guard !link.hasPrefix("/") else { throw HarnessError.invalidFixture }
                    let resolved = item.deletingLastPathComponent().appendingPathComponent(link)
                        .standardizedFileURL.resolvingSymlinksInPath()
                    guard resolved.path.hasPrefix(root.path + "/") else { throw HarnessError.invalidFixture }
                    try manager.createSymbolicLink(atPath: target.path, withDestinationPath: link)
                } else if values.isDirectory == true {
                    if [".git", ".build", "node_modules", "__pycache__", "dist", "build"].contains(item.lastPathComponent) {
                        enumerator.skipDescendants()
                    } else {
                        try manager.createDirectory(at: target, withIntermediateDirectories: true)
                    }
                } else if values.isRegularFile == true {
                    try manager.copyItem(at: item, to: target)
                }
            }
            if let enumerationError { throw enumerationError }
        } catch {
            try? manager.removeItem(at: destination)
            throw error
        }
    }
}
