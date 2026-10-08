import SwiftUI
import AppKit
import AIChatRouterKit

struct MenuBarContentView: View {
    let environment: AppEnvironment
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Open MyChatBuddy") {
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: "main")
        }

        Divider()

        Text(environment.networkStatusMonitor.isOnline ? "Online" : "Offline — local only")
            .font(.caption)

        Divider()

        SettingsLink {
            Text("Settings…")
        }

        Divider()

        Button("Quit MyChatBuddy") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q", modifiers: .command)
    }
}
