import SwiftUI

enum TranscriptRow: Identifiable {
    case message(ChatMessage)
    case activity(id: UUID, userMessageID: UUID?, entries: [ChatMessage])

    var id: UUID {
        switch self {
        case let .message(message): return message.id
        case let .activity(id, _, _): return id
        }
    }

    static func rows(for messages: [ChatMessage]) -> [TranscriptRow] {
        var rows: [TranscriptRow] = []
        var pending: [TranscriptRow] = []
        var previouslyQueued: ArraySlice<ChatMessage> = []
        var entries: [ChatMessage] = []
        var userMessageID: UUID?
        var insertion = 0

        func finishActivity() {
            guard let first = entries.first else { return }
            rows.insert(.activity(id: first.id, userMessageID: userMessageID, entries: entries), at: insertion)
            entries = []
        }

        var previousWasUser = false
        for message in messages {
            if message.queued == true {
                pending.append(.message(message))
                continue
            }
            let effort = message.role == "system" && message.text.hasPrefix("Effort:")
            // Older builds left a consumed queue item at its enqueue position. Its
            // actual execution starts at the next effort record without a user row.
            if message.role == "user", message.queued == false {
                previouslyQueued.append(message)
                continue
            }
            if effort, !previousWasUser, let started = previouslyQueued.popFirst() {
                finishActivity()
                userMessageID = started.id
                rows.append(.message(started))
            }
            previousWasUser = message.role == "user"
            if message.role == "user" {
                finishActivity()
                userMessageID = message.id
            }
            let metadata = effort || (message.role == "system" && message.text.hasPrefix("Модель:"))
            if message.role == "tool" || metadata {
                if entries.isEmpty { insertion = rows.count }
                entries.append(message)
            } else {
                rows.append(.message(message))
            }
        }
        finishActivity()
        return rows + previouslyQueued.map(TranscriptRow.message) + pending
    }
}

struct ActivityDisclosure: View {
    let entries: [ChatMessage]
    var agents: [AgentCard] = []
    var stopAgent: (UUID) -> Void = { _ in }
    @State private var expanded = false

    // Start and result records share a bracketed call ID in both current and older histories.
    static func label(for entries: [ChatMessage], hasAgents: Bool = false) -> String {
        var calls = Set<Substring>()
        var hasTools = false
        for entry in entries where entry.role == "tool" {
            hasTools = true
            if entry.text.first == "[", let end = entry.text.firstIndex(of: "]") {
                calls.insert(entry.text.dropFirst()[..<end])
            }
        }
        if !hasTools && !hasAgents { return "Параметры ответа" }
        return calls.isEmpty ? "Действия агента" : "Действия агента · \(calls.count)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button { expanded.toggle() } label: {
                HStack(spacing: 7) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.caption2.weight(.semibold)).frame(width: 10)
                    Text(Self.label(for: entries, hasAgents: !agents.isEmpty)).font(.subheadline)
                }
                .frame(maxWidth: .infinity, minHeight: 26, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(expanded ? "Развёрнуто" : "Свёрнуто")
            if expanded {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(agents) { agent in
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(agent.task).font(.subheadline.weight(.medium))
                                Text(agent.status).font(.caption)
                                if !agent.detail.isEmpty { Text(agent.detail).font(.caption).textSelection(.enabled) }
                            }
                            Spacer()
                            if agent.canStop {
                                Button("Остановить") { stopAgent(agent.id) }
                            }
                        }
                    }
                    ForEach(entries) { entry in
                        Text(entry.text)
                            .font(entry.role == "tool" ? .system(.caption, design: .monospaced) : .caption)
                            .foregroundStyle(entry.role == "tool" ? Color.primary : .secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.leading, 17)
            }
        }
        .foregroundStyle(.secondary)
    }
}
