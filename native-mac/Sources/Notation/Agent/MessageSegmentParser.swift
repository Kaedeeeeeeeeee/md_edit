import Foundation

/// One piece of an assistant message after fenced-block extraction. Messages
/// are parsed into an ordered list of these so the renderer can show prose
/// inline and fenced blocks inside their own Insertable Block container.
enum MessageSegment: Identifiable, Equatable {
    case text(id: Int, content: String)
    case insertBlock(id: Int, language: String, content: String, isClosed: Bool)

    var id: Int {
        switch self {
        case .text(let id, _): return id
        case .insertBlock(let id, _, _, _): return id
        }
    }
}

/// Splits an assistant message into an ordered `[MessageSegment]` by extracting
/// fenced code blocks (```...```) at line boundaries. Fences only count when
/// they're the entire trimmed content of a line; this avoids tripping on
/// inline backticks inside prose.
///
/// **Streaming safety**: when `isStreaming` is true, the parser is re-run on
/// every flush of the streaming buffer, so it must tolerate partial input:
///   - A line at the end of `content` with no trailing newline is treated as
///     incomplete — even if it starts with ``` we don't promote it to a fence
///     yet (the next chunk might add the language tag, or might reveal it was
///     a fragment of inline text).
///   - A fence that opens but never closes (still streaming) produces an
///     `insertBlock(... isClosed: false)` segment so the renderer can show
///     the block and stream tokens into it live.
///
/// When `isStreaming` is false the message is final: a trailing ``` line
/// closes the fence even without a trailing newline, because no more chars
/// are coming. Without this distinction, a model that ends its response on
/// the closing ``` (a very normal thing to do) leaves the block stuck in
/// "Generating…" forever.
///
/// Cost is O(n) on `content.count`. Called at most ~20Hz during streaming
/// (the controller's flush interval) on messages that top out at a few KB —
/// re-running the whole parse beats trying to incrementalize state.
func parseMessageSegments(_ content: String, isStreaming: Bool) -> [MessageSegment] {
    var segments: [MessageSegment] = []
    var nextID = 0
    var textBuffer = ""
    var inFence = false
    var fenceLang = ""
    var fenceBuffer = ""

    let endsWithNewline = content.hasSuffix("\n")
    // `components(separatedBy:)` on "a\n" yields ["a", ""] — the trailing
    // empty element is a real line marker (the last newline). We use that to
    // tell completed-line from in-progress-line below.
    let lines = content.components(separatedBy: "\n")

    for (idx, line) in lines.enumerated() {
        // The final element of `lines` only represents a finished line if the
        // input ended with a newline, OR if we know the stream is already
        // done (`!isStreaming` — no more chars are coming, so whatever is
        // there is final).
        let isFinalIncomplete = (idx == lines.count - 1) && !endsWithNewline && isStreaming
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        if inFence {
            if !isFinalIncomplete && trimmed == "```" {
                // Close fence.
                segments.append(.insertBlock(
                    id: nextID,
                    language: fenceLang,
                    content: fenceBuffer,
                    isClosed: true
                ))
                nextID += 1
                inFence = false
                fenceLang = ""
                fenceBuffer = ""
            } else {
                if !fenceBuffer.isEmpty { fenceBuffer += "\n" }
                fenceBuffer += line
            }
        } else {
            if !isFinalIncomplete && trimmed.hasPrefix("```") {
                // Flush any accumulated prose first.
                if !textBuffer.isEmpty {
                    segments.append(.text(id: nextID, content: textBuffer))
                    nextID += 1
                    textBuffer = ""
                }
                let lang = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                inFence = true
                fenceLang = lang
                fenceBuffer = ""
            } else {
                if !textBuffer.isEmpty { textBuffer += "\n" }
                textBuffer += line
            }
        }
    }

    // Tail: emit whatever's still buffered. A still-open fence becomes an
    // unclosed insertBlock so the renderer can show the partial content.
    if inFence {
        segments.append(.insertBlock(
            id: nextID,
            language: fenceLang,
            content: fenceBuffer,
            isClosed: false
        ))
    } else if !textBuffer.isEmpty {
        segments.append(.text(id: nextID, content: textBuffer))
    }

    return segments
}

// MARK: - Insert payload shaping

/// Labels we treat as prose — the block's content is inserted into the
/// document as-is, no surrounding code-fence markers. Anything else is
/// assumed to be code in some language and gets re-wrapped on insert so
/// the inserted text renders as a code block in the markdown doc.
private let proseFenceLanguages: Set<String> = [
    "",
    "draft", "rewrite", "edit", "revision",
    "email", "letter", "message",
    "outline", "summary", "intro", "conclusion", "paragraph",
    "text", "prose", "content", "insert", "markdown", "md",
    "list", "bullets"
]

/// What actually lands in the document when the user hits Insert on an
/// Insertable Block. Prose-style blocks insert their body verbatim; code
/// blocks get re-fenced so they read as code in the markdown doc.
func insertPayload(forLanguage language: String, body: String) -> String {
    if proseFenceLanguages.contains(language.lowercased()) {
        return body
    }
    return "```\(language)\n\(body)\n```"
}
