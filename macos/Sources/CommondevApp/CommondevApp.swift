import AppKit
import SwiftUI

@main
enum CommondevLauncher {
    @MainActor static func main() {
        do {
            guard let lock = try InstanceLock(directory: AppModel.defaultStorageRoot) else {
                let pid = ProcessInfo.processInfo.processIdentifier
                NSRunningApplication.runningApplications(withBundleIdentifier: "dev.commondev.app")
                    .first { $0.processIdentifier != pid }?.activate(options: [.activateAllWindows])
                return
            }
            withExtendedLifetime(lock) { CommondevApp.main() }
        } catch {
            NSAlert(error: error).runModal()
            exit(EXIT_FAILURE)
        }
    }
}

struct CommondevApp: App {
    @StateObject private var model = AppModel()
    @AppStorage("appearance") private var appearance = "system"

    @AppStorage("accentRGB") private var accent = TideAppearance.mint
    @AppStorage("windowZoom") private var zoom = 100

    private let zoomRange = 70...150
    private let zoomStep = 10

    private var scale: CGFloat { CGFloat(zoom) / 100 }

    var body: some Scene {
        Window("commondev", id: "main") {
            GeometryReader { viewport in
                ContentView(model: model)
                    .frame(width: viewport.size.width / scale, height: viewport.size.height / scale)
                    .scaleEffect(scale, anchor: .topLeading)
            }
            .ignoresSafeArea(.container, edges: .top)
            .transparentTideWindow()
            .accentColor(TideAppearance.accent(accent))
            .tint(TideAppearance.accent(accent))
            .preferredColorScheme(appearance == "light" ? .light : appearance == "dark" ? .dark : nil)
            .frame(minWidth: max(820, 770 * scale), minHeight: 560)
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                model.flushStreamingText()
            }
        }
        .defaultSize(width: 1140, height: 740)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(after: .toolbar) {
                Button("Увеличить масштаб") { changeZoom(by: zoomStep) }
                    .keyboardShortcut("+", modifiers: .command)
                    .disabled(zoom >= zoomRange.upperBound)
                Button("Уменьшить масштаб") { changeZoom(by: -zoomStep) }
                    .keyboardShortcut("-", modifiers: .command)
                    .disabled(zoom <= zoomRange.lowerBound)
                Button("Фактический размер") { zoom = 100 }
                    .keyboardShortcut("0", modifiers: .command)
                    .disabled(zoom == 100)
            }
        }
    }

    private func changeZoom(by step: Int) {
        zoom = min(zoomRange.upperBound, max(zoomRange.lowerBound, zoom + step))
    }
}
