import SwiftUI
import AIChatRouterKit

struct ModelBadgeView: View {
    let tier: ModelTier
    let displayName: String
    let tokenCount: Int?

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(displayName)
            if let tokenCount {
                Text("· \(tokenCount) tok")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption2)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Capsule().fill(Color.secondary.opacity(0.12)))
    }

    private var color: Color {
        switch tier {
        case .local: return .green
        case .cloudFast: return .blue
        case .cloudAdvanced: return .purple
        }
    }
}
