import SwiftUI
import AIChatRouterKit

struct MessageBubbleView: View {
    let message: Message
    let displayName: (String) -> String

    var body: some View {
        HStack {
            if message.role == .user { Spacer(minLength: 40) }
            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 4) {
                Text(message.content)
                    .padding(10)
                    .background(bubbleColor, in: RoundedRectangle(cornerRadius: 12))
                if message.role == .assistant, let tier = message.tier {
                    ModelBadgeView(
                        tier: tier,
                        displayName: badgeDisplayName(for: tier),
                        tokenCount: totalTokens
                    )
                }
            }
            if message.role != .user { Spacer(minLength: 40) }
        }
    }

    private var bubbleColor: Color {
        message.role == .user ? Color.accentColor.opacity(0.85) : Color.secondary.opacity(0.15)
    }

    private var totalTokens: Int? {
        let total = (message.inputTokens ?? 0) + (message.outputTokens ?? 0)
        return total > 0 ? total : nil
    }

    private func badgeDisplayName(for tier: ModelTier) -> String {
        guard let modelID = message.modelID else {
            switch tier {
            case .local: return "Local"
            case .cloudFast: return "Cloud Fast"
            case .cloudAdvanced: return "Cloud Advanced"
            }
        }
        return displayName(modelID)
    }
}
