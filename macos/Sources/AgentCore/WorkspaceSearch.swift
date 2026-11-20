import Darwin
import Foundation

enum WorkspaceSearch {
    static func find(pattern: String, workspace: URL) throws -> String {
        var matches: [String] = []
        let truncated = try visit(workspace: workspace) { file, relative in
            if fnmatch(pattern, file.lastPathComponent, 0) == 0 { matches.append(relative) }
            return matches.count >= 200
        }
        return format(matches, truncated: truncated)
    }

    static func search(query: String, workspace: URL) throws -> String {
        var matches: [String] = []
        var bytes = 0
        var omittedLongLines = false
        let truncated = try visit(workspace: workspace) { file, relative in
            try searchFile(file, omittedLongLines: &omittedLongLines) { lineNumber, line in
                guard line.contains(query) else { return false }
                let result = "\(relative):\(lineNumber): \(line.prefix(1000))"
                matches.append(result)
                bytes += result.utf8.count
                return matches.count >= 200 || bytes >= 50_000
            }
        }
        guard omittedLongLines else { return format(matches, truncated: truncated) }
        let result = matches.isEmpty
            ? "Совпадений в просмотренных строках нет." + (truncated ? "\nРезультаты ограничены." : "")
            : format(matches, truncated: truncated)
        return result + "\nСтроки длиннее 1 МБ пропущены при поиске."
    }

    /// Stream one line at a time rather than silently ignoring large files.
    /// Limit individual lines so generated or minified files cannot consume
    /// unbounded memory. The descriptor is nonblocking and verified after open
    /// so replacing an enumerated file with a FIFO cannot hang the agent.
    private static func searchFile(
        _ file: URL, omittedLongLines: inout Bool,
        eachLine: (Int, String) -> Bool
    ) throws -> Bool {
        let descriptor = open(file.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return false }

        let lineLimit = 1_000_000
        var line = Data()
        var skippingLine = false
        var lineNumber = 1
        var buffer = [UInt8](repeating: 0, count: 16_384)

        func appendSegment(_ segment: ArraySlice<UInt8>) {
            guard !skippingLine else { return }
            guard line.count + segment.count <= lineLimit else {
                omittedLongLines = true
                skippingLine = true
                line.removeAll(keepingCapacity: false)
                return
            }
            line.append(contentsOf: segment)
        }

        func consumeLine() -> Bool {
            defer {
                line.removeAll(keepingCapacity: true)
                skippingLine = false
                lineNumber += 1
            }
            guard !skippingLine, let text = String(data: line, encoding: .utf8) else { return false }
            return eachLine(lineNumber, text)
        }

        while true {
            try Task.checkCancellation()
            let count = read(descriptor, &buffer, buffer.count)
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                return false
            }
            // NUL is a reliable binary-file indicator for the common project
            // formats that search_files is intended to skip.
            if buffer[..<count].contains(0) { return false }
            var start = 0
            for index in 0..<count where buffer[index] == 10 {
                appendSegment(buffer[start..<index])
                if consumeLine() { return true }
                start = index + 1
            }
            appendSegment(buffer[start..<count])
        }
        if !line.isEmpty || skippingLine { return consumeLine() }
        return false
    }

    private static func visit(workspace: URL, each: (URL, String) throws -> Bool) throws -> Bool {
        guard let enumerator = FileManager.default.enumerator(
            at: workspace, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
        ) else { throw CocoaError(.fileReadUnknown) }
        var count = 0
        for case let item as URL in enumerator {
            try Task.checkCancellation()
            let values = try item.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
            if values.isSymbolicLink == true { enumerator.skipDescendants(); continue }
            if values.isDirectory == true && [".git", ".build", "node_modules"].contains(item.lastPathComponent) {
                enumerator.skipDescendants()
                continue
            }
            guard values.isRegularFile == true else { continue }
            let resolved = item.standardizedFileURL.resolvingSymlinksInPath().path
            guard resolved.hasPrefix(workspace.path + "/") else { continue }
            let relative = String(resolved.dropFirst(workspace.path.count + 1))
            count += 1
            if try each(item, relative) || count >= 10_000 { return true }
        }
        return false
    }

    private static func format(_ results: [String], truncated: Bool) -> String {
        let contents = results.isEmpty ? "Совпадений нет." : results.joined(separator: "\n")
        return truncated ? contents + "\nРезультаты ограничены." : contents
    }
}
