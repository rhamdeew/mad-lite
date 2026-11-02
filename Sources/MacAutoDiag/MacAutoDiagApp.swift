import VazCore
import AppKit
import SwiftUI

@main
struct MacAutoDiagApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()
    @State private var diagnostics = DiagnosticsModel()
    @State private var loaderLog = LoaderLog()
    @State private var agent = AgentServer()
    /// Local MCP endpoint for an agent (Диагностика → Доступ для агента); `--agent` turns it on for one run.
    @AppStorage("agentEnabled") private var agentEnabled = false

    var body: some Scene {
        WindowGroup(Edition.name) {
            ContentView()
                .environment(model)
                .environment(diagnostics)
                .environment(loaderLog)
                .environment(agent)
                .frame(minWidth: 900, minHeight: 600)
                .task { updateAgent() }
                .onChange(of: agentEnabled) { updateAgent() }
        }
        .defaultSize(width: 1300, height: 850)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Открыть прошивку…") { model.presentOpenPanel(for: .primary) }
                    .keyboardShortcut("o")
                Button("Сравнить с…") { model.presentOpenPanel(for: .comparison) }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                    .disabled(model.primary == nil)
                Button("Открыть лог для разбора…") { model.presentLogPanel() }
                    .keyboardShortcut("l", modifiers: [.command, .shift])
                Button("Открыть снимок блока…") { model.presentSnapshotPanel() }
                    .keyboardShortcut("b", modifiers: [.command, .shift])
                Button("Открыть карту ChipTuningPRO…") { model.presentMapPanel() }
                    .keyboardShortcut("m", modifiers: [.command, .option])
                    .disabled(model.primary == nil)
            }
            // Recording controls live in the menu so their shortcuts work whatever has focus
            // (a text field, a slider) and don't fight the system ⌘M «Minimize».
            CommandMenu("Диагностика") {
                Button(diagnostics.log == nil ? "Начать запись лога" : "Остановить запись лога") {
                    if diagnostics.log == nil { diagnostics.startRecording() } else { diagnostics.stopRecording() }
                }
                .keyboardShortcut("r")
                .disabled(diagnostics.state != .connected && diagnostics.log == nil)
                Button("Поставить метку") { diagnostics.mark("") }
                    .keyboardShortcut("k")
                    .disabled(diagnostics.log == nil)
                Divider()
                Toggle("Доступ для агента (MCP, только чтение)", isOn: $agentEnabled)
            }
            CommandGroup(replacing: .saveItem) {
                Button("Сохранить как…") { model.presentSavePanel() }
                    .keyboardShortcut("s")
                    .disabled(model.primary == nil)
            }
        }
    }
}

extension MacAutoDiagApp {
    private func updateAgent() {
        if agentEnabled || CommandLine.arguments.contains("--agent") {
            agent.start(tools: AgentTools(app: model, diag: diagnostics, loaderLog: loaderLog))
        } else {
            agent.stop()
        }
    }
}

/// Lets `swift run` show a regular app with a Dock icon and a focused window.
final class AppDelegate: NSObject, NSApplicationDelegate {
    // Without a bundle (`swift run`) the process starts as a background app: make it a regular
    // one before launch finishes, then bring it and its window to the front.
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        // Dock icon for `swift run` too; the .app from tools/run-app.sh also carries AppIcon.icns.
        if let url = Bundle.module.url(forResource: "AppIcon", withExtension: "png"),
           let icon = NSImage(contentsOf: url) {
            NSApp.applicationIconImage = icon
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Honoured when launched by LaunchServices (tools/run-app.sh); from a terminal macOS 14+
        // keeps the terminal in front.
        NSApp.activate()
        DispatchQueue.main.async { NSApp.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
