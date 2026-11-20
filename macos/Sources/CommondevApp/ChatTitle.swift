import AgentCore
import Foundation

enum ChatTitle {
    static let placeholder = "Новый чат"

    static func provisional(_ prompt: String) -> String {
        let words = prompt.split(whereSeparator: \.isWhitespace)
        let line = words.joined(separator: " ")
        guard !line.isEmpty else { return placeholder }
        guard line.count > 56 else { return line }
        let prefix = line.prefix(55)
        let end = prefix.lastIndex(of: " ") ?? prefix.endIndex
        return String(prefix[..<end]) + "…"
    }

    static func generate(for prompt: String, using client: OpenAICompatibleClient) async throws -> String? {
        let reply = try await client.complete(messages: [
            ["role": .string("system"), "content": .string(
                "Write a short, specific sidebar title for this chat in the user's language. Summarize the task in 2–7 words. Return just the title on one line, without quotes, Markdown or a final period. The next message is the subject to summarize."
            )],
            ["role": .string("user"), "content": .string(String(prompt.prefix(2_000)))]
        ], tools: [], reasoningEffort: .low)
        let title = reply.text.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"«»“”"))
        guard reply.toolCalls.isEmpty, !title.isEmpty, title.count <= 70,
              title != placeholder, !title.contains(where: \.isNewline) else { return nil }
        return title
    }
}
