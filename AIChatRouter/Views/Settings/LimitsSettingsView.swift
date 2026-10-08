import SwiftUI
import AIChatRouterKit

struct LimitsSettingsView: View {
    @State private var viewModel: LimitsSettingsViewModel

    init(environment: AppEnvironment) {
        _viewModel = State(initialValue: LimitsSettingsViewModel(settingsStore: environment.settingsStore))
    }

    var body: some View {
        Form {
            Section("Per-Conversation Soft Cap") {
                TextField("Tokens (warns only, never blocks)", text: $viewModel.perConversationSoftCapTokens)
                    .onSubmit { viewModel.save() }
            }

            Section("Budget Caps (hard — downgrades tier)") {
                TextField("Daily budget (USD)", text: $viewModel.dailyBudgetUSD)
                    .onSubmit { viewModel.save() }
                TextField("Monthly budget (USD)", text: $viewModel.monthlyBudgetUSD)
                    .onSubmit { viewModel.save() }
            }

            Section("Per-Tier Daily Call Caps (hard — downgrades tier)") {
                TextField("Cloud Fast: max calls/day", text: $viewModel.cloudFastDailyCallCap)
                    .onSubmit { viewModel.save() }
                TextField("Cloud Advanced: max calls/day", text: $viewModel.cloudAdvancedDailyCallCap)
                    .onSubmit { viewModel.save() }
            }

            Section("Attachments") {
                TextField("Max combined size (characters)", text: $viewModel.attachmentSizeCapCharacters)
                    .onSubmit { viewModel.save() }
                Text("Leave blank or 0 to use the default (\(AttachmentStore.defaultCharacterLimit)). Large values may exceed the local model's context window and increase per-message cost on cloud tiers.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Section("Image Attachments") {
                TextField("Max source image size (bytes)", text: $viewModel.imageAttachmentSizeCapBytes)
                    .onSubmit { viewModel.save() }
                Text("Leave blank or 0 to use the default (\(AppSettingsStore.defaultImageAttachmentSizeCapBytes) bytes ≈ \(AppSettingsStore.defaultImageAttachmentSizeCapBytes / 1_000_000)MB). Checked before downscaling, so an oversized source photo is rejected outright rather than silently downsized.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Button("Save") { viewModel.save() }

            Text("Leave a field blank to disable that cap. Hard caps downgrade Advanced → Fast → Local rather than blocking the request.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
    }
}
