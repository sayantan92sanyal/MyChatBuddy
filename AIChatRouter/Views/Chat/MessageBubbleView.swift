import SwiftUI
import AppKit
import MarkdownUI
import AIChatRouterKit

struct MessageBubbleView: View {
    let message: Message
    let imageAttachment: ImageAttachment?
    let displayName: (String) -> String
    @State private var sourcesExpanded = false

    var body: some View {
        HStack {
            if message.role == .user { Spacer(minLength: 40) }
            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 4) {
                if let imageAttachment, let nsImage = NSImage(data: imageAttachment.imageData) {
                    Image(nsImage: nsImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: 240, maxHeight: 240)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                // Only the model's replies get Markdown rendering — a user's own
                // typed message stays literal, since they didn't necessarily
                // intend "#" or "-" at the start of a line as formatting.
                Group {
                    if message.role == .assistant {
                        Markdown(message.content)
                    } else {
                        Text(message.content)
                    }
                }
                .padding(10)
                .background(bubbleColor, in: RoundedRectangle(cornerRadius: 12))
                if message.role == .assistant, let tier = message.tier {
                    ModelBadgeView(
                        tier: tier,
                        displayName: badgeDisplayName(for: tier),
                        tokenCount: totalTokens
                    )
                }
                if let citations = Message.decodeCitations(message.citationsJSON), !citations.isEmpty {
                    sourcesDisclosure(citations)
                }
            }
            if message.role != .user { Spacer(minLength: 40) }
        }
    }

    private func sourcesDisclosure(_ citations: [SearchCitation]) -> some View {
        DisclosureGroup(isExpanded: $sourcesExpanded) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(citations, id: \.url) { citation in
                    if let url = URL(string: citation.url) {
                        Link(citation.title ?? citation.url, destination: url)
                            .font(.caption2)
                            .lineLimit(1)
                    } else {
                        Text(citation.title ?? citation.url)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            .padding(.top, 2)
        } label: {
            Text("Sources (\(citations.count))")
                .font(.caption2)
                .foregroundStyle(.secondary)
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
