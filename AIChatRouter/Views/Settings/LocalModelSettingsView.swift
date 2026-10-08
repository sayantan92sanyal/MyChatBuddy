import SwiftUI
import AIChatRouterKit

struct LocalModelSettingsView: View {
    @State private var textViewModel: LocalModelSettingsViewModel
    @State private var visionViewModel: LocalModelSettingsViewModel

    init(modelManager: LocalModelManager, settingsStore: AppSettingsStore) {
        _textViewModel = State(initialValue: LocalModelSettingsViewModel(
            kind: .text, modelManager: modelManager, settingsStore: settingsStore
        ))
        _visionViewModel = State(initialValue: LocalModelSettingsViewModel(
            kind: .vision, modelManager: modelManager, settingsStore: settingsStore
        ))
    }

    var body: some View {
        Form {
            section(for: textViewModel, title: "Text Model")
            section(for: visionViewModel, title: "Vision Model")
        }
        .padding()
        .task {
            await textViewModel.refreshStatus()
            await visionViewModel.refreshStatus()
        }
    }

    private func section(for viewModel: LocalModelSettingsViewModel, title: String) -> some View {
        Section(title) {
            Picker("Model", selection: Binding(
                get: { viewModel.selectedModelID },
                set: { newValue in
                    viewModel.selectedModelID = newValue
                    viewModel.save()
                    Task { await viewModel.refreshStatus() }
                }
            )) {
                ForEach(viewModel.options) { option in
                    Text(option.displayName).tag(option.id)
                }
            }

            Text(viewModel.statusMessage)
                .font(.caption)
                .foregroundStyle(.secondary)

            if let progress = viewModel.progress, viewModel.isDownloading {
                ProgressView(value: progress)
            }

            Button(viewModel.isDownloading ? "Downloading…" : "Download / Load Model") {
                Task { await viewModel.downloadAndLoad() }
            }
            .disabled(viewModel.isDownloading)
        }
    }
}
