import SwiftUI
import AIChatRouterKit

@main
struct AIChatRouterApp: App {
    private let environment: AppEnvironment

    init() {
        do {
            let database = try AppDatabase.openDefault()
            environment = AppEnvironment(database: database)
        } catch {
            fatalError("Failed to open database: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup(id: "main") {
            RootSplitView(environment: environment)
        }
        Settings {
            SettingsView(environment: environment)
        }
        MenuBarExtra("MyChatBuddy", systemImage: "bubble.left.and.bubble.right.fill") {
            MenuBarContentView(environment: environment)
        }
    }
}
