import SwiftUI

struct MessageComposerView: View {
    @Binding var text: String
    var isSending: Bool
    var onSend: () -> Void
    var onAttach: () -> Void

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            Button(action: onAttach) {
                Image(systemName: "paperclip")
            }
            .buttonStyle(.plain)
            .disabled(isSending)
            .help("Attach a file")

            TextField("Message", text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...6)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.1)))
                .onKeyPress(.return, phases: .down) { keyPress in
                    guard !keyPress.modifiers.contains(.shift) else { return .ignored }
                    guard !isSending, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        return .ignored
                    }
                    onSend()
                    return .handled
                }

            Button(action: onSend) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
            }
            .buttonStyle(.plain)
            .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSending)
            .keyboardShortcut(.return, modifiers: .command)
        }
        .padding(10)
    }
}
