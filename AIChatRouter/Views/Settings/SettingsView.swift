import SwiftUI
import AIChatRouterKit

struct SettingsView: View {
    let environment: AppEnvironment

    var body: some View {
        TabView {
            APIKeysSettingsView()
                .tabItem { Label("API Keys", systemImage: "key") }

            LocalModelSettingsView(modelManager: environment.localModelManager)
                .tabItem { Label("Local Model", systemImage: "cpu") }

            TierProviderMappingView(environment: environment)
                .tabItem { Label("Routing", systemImage: "arrow.triangle.branch") }

            LimitsSettingsView(environment: environment)
                .tabItem { Label("Limits", systemImage: "gauge.with.dots.needle.50percent") }

            UsageDashboardView(environment: environment)
                .tabItem { Label("Usage", systemImage: "chart.bar") }
        }
        .frame(width: 520, height: 420)
    }
}
