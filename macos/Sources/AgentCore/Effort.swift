import Foundation

public enum Effort: String, CaseIterable, Codable, Sendable {
    case auto, low, medium, high, xhigh

    public var title: String {
        switch self {
        case .auto: return "Auto"
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        case .xhigh: return "XHigh"
        }
    }

    public func resolved(for task: String) -> Effort {
        guard self == .auto else { return self }
        let text = task.lowercased()
        let broadTerms = ["миграц", "архитектур", "безопасност", "migration", "security", "architecture"]
        if task.count > 500 || broadTerms.contains(where: text.contains) { return .high }
        if task.count < 80 { return .low }
        return .medium
    }

    public var maxModelCalls: Int {
        switch self {
        case .low: return 8
        case .auto, .medium: return 15
        case .high: return 30
        case .xhigh: return 60
        }
    }

    public var maxToolCalls: Int { maxModelCalls * 2 }

    /// XHigh maps to the broadly supported high value; Auto resolves before requests.
    public var reasoningEffort: ReasoningEffort {
        switch self {
        case .low: return .low
        case .auto, .medium: return .medium
        case .high, .xhigh: return .high
        }
    }

    public var instructions: String {
        switch self {
        case .low: return "Focus on the requested change and run the most relevant check."
        case .auto, .medium: return "Inspect related call sites and run relevant tests."
        case .high: return "Investigate alternative causes, related call sites and edge cases. Verify changes."
        case .xhigh: return "Investigate competing hypotheses and verify regressions and edge cases across affected modules."
        }
    }
}
