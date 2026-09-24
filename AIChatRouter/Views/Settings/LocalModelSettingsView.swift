import SwiftUI
import AIChatRouterKit

struct LocalModelSettingsView: View {
    @State private var viewModel: LocalModelSettingsViewModel

    init(modelManager: LocalModelManager) {
        _viewModel = State(initialValue: LocalModelSettingsViewModel(modelManager: modelManager))
    }

    var body: some View {
        Form {
            Section("Local Model") {
                Picker("Model", selection: $viewModel.selectedModelID) {
                    ForEach(viewModel.options) { option in
                        Text(option.displayName).tag(option.id)
                    }
                }
                .onChange(of: viewModel.selectedModelID) {
                    Task { await viewModel.refreshStatus() }
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
        .padding()
        .task { await viewModel.refreshStatus() }
    }
}
