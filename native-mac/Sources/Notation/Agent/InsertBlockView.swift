import SwiftUI
import AppKit

/// Renders one fenced-block segment from an assistant message as an
/// "Insertable Block": a bordered card with a small header (language label
/// + Copy + Insert) and the block's content rendered inside.
///
/// Used by `AgentMessageBubble` for every `.insertBlock` segment. Prose and
/// explanations sit outside the card; only this card has direct affordances
/// for committing the block to the document.
struct InsertBlockView: View {
    let language: String
    let content: String
    /// True once the closing ``` fence has arrived. Insert is disabled while
    /// the block is still streaming because the body is not yet final.
    let isClosed: Bool
    /// True while the parent message itself is streaming. Even after a block
    /// closes mid-stream, the message-level streaming flag governs whether
    /// the inner markdown render swaps from plain text to AttributedString
    /// (we keep everything plain text while the message is in flight to keep
    /// per-flush rendering cheap).
    let isMessageStreaming: Bool
    let onCopy: () -> Void
    let onInsert: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().opacity(0.4)
            body_
        }
        .background(Color.primary.opacity(0.04))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
        )
        .clipShape(.rect(cornerRadius: 10))
    }

    // MARK: - Sections

    private var header: some View {
        HStack(spacing: 8) {
            Text(displayLanguage)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            Spacer()
            if !isClosed {
                Text("Generating…")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            Button(action: onCopy) {
                Label("Copy", systemImage: "doc.on.doc")
                    .labelStyle(.titleOnly)
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)
            .help("Copy block to clipboard")
            .disabled(content.isEmpty)

            Button(action: onInsert) {
                Label("Insert", systemImage: "text.insert")
                    .labelStyle(.titleOnly)
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.mini)
            .help(isClosed ? "Insert block at cursor" : "Available once the block finishes")
            .disabled(!isClosed || content.isEmpty)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var body_: some View {
        Group {
            if content.isEmpty {
                Text(" ")  // reserve one line of height so the empty block isn't visually collapsed
            } else if isMessageStreaming {
                Text(content)
            } else {
                Text(InsertBlockMarkdownCache.attributed(for: content))
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var displayLanguage: String {
        let trimmed = language.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return "Block" }
        // Title-case for descriptive labels (draft → Draft, email → Email).
        // Code language identifiers stay lowercase by convention.
        if let first = trimmed.first, first.isLetter {
            return trimmed.prefix(1).uppercased() + trimmed.dropFirst()
        }
        return trimmed
    }
}

/// Standalone parse cache for Insertable Block bodies. Keyed only by content
/// hash because block IDs are local to a single message and would collide
/// across messages otherwise. Content is immutable once `isClosed` so cache
/// hits dominate after the stream settles.
@MainActor
private enum InsertBlockMarkdownCache {
    private static var storage: [Int: AttributedString] = [:]
    private static let options = AttributedString.MarkdownParsingOptions(
        interpretedSyntax: .inlineOnlyPreservingWhitespace
    )

    static func attributed(for content: String) -> AttributedString {
        let hash = content.hashValue
        if let cached = storage[hash] { return cached }
        let parsed = (try? AttributedString(markdown: content, options: options))
            ?? AttributedString(content)
        storage[hash] = parsed
        return parsed
    }
}

/// Convenience for the Copy action — writes the given string to the system
/// pasteboard as plain text.
@MainActor
func copyBlockToPasteboard(_ content: String) {
    let pb = NSPasteboard.general
    pb.clearContents()
    pb.setString(content, forType: .string)
}
