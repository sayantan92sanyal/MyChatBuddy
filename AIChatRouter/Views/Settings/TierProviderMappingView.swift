import SwiftUI
import AIChatRouterKit

struct TierProviderMappingView: View {
    @State private var viewModel: TierProviderMappingViewModel
    @State private var sensitivityValue: Double
    private let settingsStore: AppSettingsStore

    init(environment: AppEnvironment) {
        self.settingsStore = environment.settingsStore
        _viewModel = State(initialValue: TierProviderMappingViewModel(
            settingsStore: environment.settingsStore,
            defaultMapping: environment.defaultTierModelMapping,
            fastOptions: environment.cloudFastOptions,
            advancedOptions: environment.cloudAdvancedOptions
        ))
        _sensitivityValue = State(
            initialValue: Self.value(for: environment.settingsStore.loadRoutingSensitivity())
        )
    }

    var body: some View {
        Form {
            Section("Cloud Fast Tier") {
                Picker("Provider / Model", selection: $viewModel.selectedFastID) {
                    ForEach(viewModel.fastOptions) { option in
                        Text(option.descriptor.displayName).tag(option.id)
                    }
                }
                .onChange(of: viewModel.selectedFastID) { viewModel.save() }
            }

            Section("Cloud Advanced Tier") {
                Picker("Provider / Model", selection: $viewModel.selectedAdvancedID) {
                    ForEach(viewModel.advancedOptions) { option in
                        Text(option.descriptor.displayName).tag(option.id)
                    }
                }
                .onChange(of: viewModel.selectedAdvancedID) { viewModel.save() }
            }

            Text("The router only ever picks a tier (Local / Cloud Fast / Cloud Advanced) — this mapping decides which provider and model actually serves each cloud tier.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Section("Routing Sensitivity") {
                Slider(value: $sensitivityValue, in: 0...2, step: 1)
                    .onChange(of: sensitivityValue) { _, newValue in
                        settingsStore.saveRoutingSensitivity(Self.sensitivity(for: newValue))
                    }
                HStack {
                    Text("Prefer Local")
                    Spacer()
                    Text("Balanced")
                    Spacer()
                    Text("Prefer Cloud")
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
        .padding()
    }

    private static func value(for sensitivity: RoutingSensitivity) -> Double {
        switch sensitivity {
        case .preferLocal: return 0
        case .balanced: return 1
        case .preferCloud: return 2
        }
    }

    private static func sensitivity(for value: Double) -> RoutingSensitivity {
        switch value {
        case ..<0.5: return .preferLocal
        case 0.5..<1.5: return .balanced
        default: return .preferCloud
        }
    }
}
