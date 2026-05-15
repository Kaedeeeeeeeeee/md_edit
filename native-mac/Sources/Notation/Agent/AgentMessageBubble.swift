import SwiftUI

/// One chat message row. User messages render as a tinted blue bubble
/// (right-aligned, capped width). Assistant messages render flat on the card
/// — no background, no rounded edges — and are split into ordered segments:
/// prose renders inline, fenced code blocks render inside their own
/// `InsertBlockView` container with Copy / Insert actions on the block.
struct AgentMessageBubble: View {
    let message: AgentChatController.Message
    let isStreaming: Bool
    /// Invoked with the block body that should land in the document. The
    /// caller (AgentCard) routes this to `AgentChatController`.
    let onInsertBlock: (String) -> Void

    var body: some View {
        switch message.role {
        case .user:
            userRow
        case .assistant:
            assistantRow
        }
    }

    // MARK: - User row

    private var userRow: some View {
        HStack(alignment: .top, spacing: 0) {
            Spacer(minLength: 32)
            Text(message.content)
                .textSelection(.enabled)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.accentColor.opacity(0.92))
                .foregroundStyle(.white)
                .clipShape(.rect(cornerRadius: 14))
        }
    }

    // MARK: - Assistant row

    private var assistantRow: some View {
        VStack(alignment: .leading, spacing: 12) {
            if message.content.isEmpty {
                ThinkingDots()
                    .padding(.vertical, 4)
            } else {
                ForEach(parseMessageSegments(message.content, isStreaming: isStreaming)) { segment in
                    switch segment {
                    case .text(_, let text):
                        proseText(text)
                    case .insertBlock(_, let lang, let body, let isClosed):
                        InsertBlockView(
                            language: lang,
                            content: body,
                            isClosed: isClosed,
                            isMessageStreaming: isStreaming,
                            onCopy: { copyBlockToPasteboard(body) },
                            onInsert: { onInsertBlock(insertPayload(forLanguage: lang, body: body)) }
                        )
                    }
                }
            }
        }
    }

    /// Renders a prose segment. Plain text while the message is streaming
    /// (markdown parse on every flush is too expensive); once the stream
    /// settles each segment switches to a cached AttributedString.
    @ViewBuilder
    private func proseText(_ text: String) -> some View {
        if isStreaming {
            Text(text)
                .textSelection(.enabled)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text(MarkdownCache.attributed(messageID: message.id, content: text))
                .textSelection(.enabled)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Process-wide cache for parsed assistant prose segments. Keyed by message
/// id + the segment text's hash — one message can contain multiple prose
/// segments now (interleaved with fenced blocks), and each gets its own
/// cache slot. Hash check guards against a re-stream of the same id serving
/// stale formatting.
@MainActor
enum MarkdownCache {
    private static var storage: [String: AttributedString] = [:]
    private static let options = AttributedString.MarkdownParsingOptions(
        interpretedSyntax: .inlineOnlyPreservingWhitespace
    )

    static func attributed(messageID: String, content: String) -> AttributedString {
        let key = "\(messageID)#\(content.hashValue)"
        if let cached = storage[key] { return cached }
        let parsed = (try? AttributedString(markdown: content, options: options))
            ?? AttributedString(content)
        storage[key] = parsed
        return parsed
    }
}

private struct ThinkingDots: View {
    @State private var phase: CGFloat = 0

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(Color.primary.opacity(0.4))
                    .frame(width: 5, height: 5)
                    .scaleEffect(scale(for: i))
            }
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                phase = 1
            }
        }
    }

    private func scale(for i: Int) -> CGFloat {
        let offset = CGFloat(i) * 0.25
        let v = sin(.pi * 2 * (phase + offset))
        return 0.7 + 0.3 * (0.5 + 0.5 * v)
    }
}
