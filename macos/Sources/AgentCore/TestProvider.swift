import Foundation

/// A deterministic provider for the stage-one Calculator fixture.
/// It reproduces one debugging workflow without contacting a model.
public struct TestProvider: AgentProvider {
    private let sourcePath = "Sources/Calculator/Calculator.swift"

    public init() {}

    public func next(task: String, results: [ToolResult]) throws -> ProviderResponse {
        switch results.count {
        case 0:
            return .toolCall(ToolCall(id: "test-before", action: .command("swift test")))
        case 1:
            guard let result = results.last, let exitCode = result.exitCode else {
                return .complete(message: "Не удалось запустить исходный тест.", success: false)
            }
            guard exitCode != 0 else {
                return .complete(message: "Исходный тест уже проходит. Правка не требуется.", success: true)
            }
            guard result.output.contains("testAddingTwoNumbers"),
                  result.output.contains("XCTAssertEqual failed") else {
                return .complete(
                    message: "Не подтверждено падение теста сложения. Проверьте вывод сборки; правка не выполнена.",
                    success: false
                )
            }
            return .toolCall(ToolCall(id: "read-source", action: .read(path: sourcePath)))
        case 2:
            guard let result = results.last, result.succeeded, result.output.contains("return a - b") else {
                return .complete(message: "Ожидаемый фрагмент не найден. Исправление остановлено.", success: false)
            }
            return .toolCall(ToolCall(
                id: "fix-source",
                action: .replace(path: sourcePath, old: "return a - b", new: "return a + b")
            ))
        case 3:
            guard results.last?.succeeded == true else {
                return .complete(message: "Правка не применена. Проверка остановлена.", success: false)
            }
            return .toolCall(ToolCall(id: "test-after", action: .command("swift test")))
        case 4:
            guard results.last?.succeeded == true else {
                return .complete(message: "Повторная проверка не прошла или была отклонена.", success: false)
            }
            return .complete(message: "Тест прошёл после исправления.", success: true)
        default:
            return .complete(message: "Неожиданное состояние сценария.", success: false)
        }
    }
}
