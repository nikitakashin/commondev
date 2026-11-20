import AgentCore
import Foundation

@main
struct ModelProbe {
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard arguments.count == 3, let endpoint = URL(string: arguments[0]),
              let scheme = endpoint.scheme, ["http", "https"].contains(scheme),
              endpoint.host != nil else {
            fputs("Usage: commondev-model <chat-completions-URL> <model> <prompt>\n", stderr)
            fputs("Sends one streaming request without executing tools. Set COMMONDEV_API_KEY if required.\n", stderr)
            exit(2)
        }
        let apiKey = ProcessInfo.processInfo.environment["COMMONDEV_API_KEY"]
        let client = OpenAICompatibleClient(endpoint: endpoint, model: arguments[1], apiKey: apiKey)
        do {
            let response = try await client.complete(
                messages: [["role": .string("user"), "content": .string(arguments[2])]],
                tools: []
            ) { chunk in
                print(chunk, terminator: "")
                fflush(stdout)
            }
            print()
            if let route = response.routedVia { fputs("Маршрут: \(route)\n", stderr) }
            if !response.toolCalls.isEmpty {
                fputs("Получены вызовы инструментов, в режиме проверки они не выполняются.\n", stderr)
            }
        } catch {
            fputs("\nОшибка запроса: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}
