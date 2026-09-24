import SwiftUI
import AIChatRouterKit

struct APIKeysSettingsView: View {
    @State private var anthropicKey = ""
    @State private var openAIKey = ""
    @State private var statusMessage: String?

    private let keychain = KeychainStore()

    var body: some View {
        Form {
            Section("Anthropic") {
                SecureField("API Key", text: $anthropicKey)
                Button("Save Anthropic Key") {
                    save(anthropicKey, account: AnthropicProvider.apiKeyAccount, label: "Anthropic")
                }
                .disabled(anthropicKey.isEmpty)
            }

            Section("OpenAI") {
                SecureField("API Key", text: $openAIKey)
                Button("Save OpenAI Key") {
                    save(openAIKey, account: OpenAIProvider.apiKeyAccount, label: "OpenAI")
                }
                .disabled(openAIKey.isEmpty)
            }

            if let statusMessage {
                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .task { loadExistingKeys() }
    }

    private func loadExistingKeys() {
        if let key = (try? keychain.value(forAccount: AnthropicProvider.apiKeyAccount)) ?? nil {
            anthropicKey = key
        }
        if let key = (try? keychain.value(forAccount: OpenAIProvider.apiKeyAccount)) ?? nil {
            openAIKey = key
        }
    }

    private func save(_ key: String, account: String, label: String) {
        do {
            try keychain.setValue(key, forAccount: account)
            statusMessage = "\(label) key saved."
        } catch {
            statusMessage = "Failed to save \(label) key: \(error.localizedDescription)"
        }
    }
}
