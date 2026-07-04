import Foundation
import Observation

/// Owns the AI Assistant chat — message list, streaming lifecycle, abort,
/// per-document persistence, and the editor-bridge call sites for "Insert at
/// cursor" / "Replace selection". One instance lives in the main editor scene
/// and is shared by the SwiftUI overlay (FAB + card) via SwiftUI's environment.
///
/// LLM streaming goes through `AIService.shared.runStreamingRequest` directly;
/// the WebView is only consulted for editor-side operations (fetching document
/// markdown for context, applying assistant output to the BlockNote document).
@Observable
@MainActor
final class AgentChatController {
    struct Message: Identifiable, Equatable {
        enum Role: String, Codable, Equatable { case user, assistant }
        let id: String
        let role: Role
        var content: String
    }

    /// System prompt for the chat surface. Teaches the model to wrap any
    /// content the user might want to drop into their document inside a
    /// fenced code block with a descriptive label; explanations and
    /// conversation stay as plain prose. The renderer downstream parses out
    /// these fenced blocks and presents them as Insertable Blocks with their
    /// own Copy / Insert actions.
    ///
    /// Distinct from `AIService`'s default rewrite-selection prompt — that
    /// one is built for the popup AI ("rewrite ONLY the SELECTED text") and
    /// would steer the model into the wrong mode in a free chat context.
    private static let chatSystemPrompt = """
        You are an AI writing assistant embedded inside a Markdown editor. The user is working on a document and is asking for your help.

        When you produce content that the user might want to drop directly into their document — a draft paragraph, a rewrite of an existing passage, an email body, an outline, a bulleted list, a code snippet — wrap that content in a fenced code block with a short, descriptive label, for example:

        ```draft
        ...drafted paragraph here...
        ```

        ```rewrite
        ...rewritten passage here...
        ```

        ```email
        ...email body here...
        ```

        ```outline
        - point one
        - point two
        ```

        Use these fenced blocks ONLY for content meant to be inserted into the document. Conversation, explanations, clarifying questions, reasoning, and meta-comments should be written as ordinary prose OUTSIDE any fenced block. Never wrap explanations, summaries of what you're about to do, or follow-up questions in a fenced block.

        If the user is just asking a question and there's nothing to insert (e.g. "what is CAP theorem?"), answer in prose only, with no fenced blocks at all.
        """

    // MARK: - Observable state

    var isOpen: Bool = false
    private(set) var messages: [Message] = []
    private(set) var isStreaming: Bool = false
    private(set) var errorMessage: String? = nil
    /// Composer toggle — "Include current doc as context". Mirrors the
    /// checkbox the user can flip below the textarea. Honored on the first
    /// turn of a fresh conversation only (subsequent turns don't re-attach
    /// the doc — the model already has it in its context window).
    var includeDocumentContext: Bool = true

    // MARK: - Internals

    /// Backing transcript actually sent to the LLM. Diverges from `messages`
    /// on the first turn when `includeDocumentContext` is on — the wire user
    /// message carries the document context, while the bubble shown to the
    /// user only carries their typed text.
    private var wireTranscript: [(role: String, content: String)] = []
    private var includedDocOnce: Bool = false
    private var streamingTask: Task<Void, Never>? = nil
    private var currentDocumentURL: URL?
    private var persistTask: Task<Void, Never>? = nil

    /// Streaming-delta coalescing. Per-delta state mutations are the dominant
    /// cost during a streaming response — every mutation triggers a SwiftUI
    /// re-evaluation of the message list and a LazyVStack remeasure of the
    /// growing bubble. We buffer incoming chunks and flush at most every
    /// `deltaFlushInterval`, which cuts re-render frequency from "as fast as
    /// the network delivers" down to ~20 Hz.
    private var pendingDeltaBuffer: String = ""
    private var pendingDeltaTargetID: String? = nil
    private var deltaFlushTask: Task<Void, Never>? = nil
    private static let deltaFlushInterval: Duration = .milliseconds(50)

    let bridge: EditorJSBridge

    init(bridge: EditorJSBridge) {
        self.bridge = bridge
    }

    // MARK: - Document binding

    /// Re-hydrates the conversation for a freshly-opened document. Cancels any
    /// in-flight stream, flushes any pending persist task, then loads the
    /// per-document chat history from `AgentChatStore`. Called by ContentView
    /// when `AppModel.currentFileURL` changes.
    func bind(to documentURL: URL?) {
        if documentURL == currentDocumentURL { return }
        abort()
        flushPendingPersist()
        currentDocumentURL = documentURL
        errorMessage = nil
        let persisted = AgentChatStore.load(for: documentURL)
        messages = persisted.compactMap { p in
            guard let role = Message.Role(rawValue: p.role) else { return nil }
            return Message(id: p.id, role: role, content: p.content)
        }
        // Reconstruct wire transcript from loaded history; we treat reloaded
        // chats as "already past first turn" so we don't re-inject the doc on
        // the user's next message (the model already saw it in the prior run).
        wireTranscript = messages.map { ($0.role.rawValue, $0.content) }
        includedDocOnce = !messages.isEmpty
    }

    // MARK: - User actions

    func toggle() { isOpen.toggle() }

    func send(_ rawText: String) {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isStreaming else { return }

        // Pro gating. We check before appending bubbles so a non-Pro user
        // tapping Send doesn't see their message land in the chat with no
        // response — the paywall sheet appearing is the clear signal.
        guard EntitlementState.shared.isPro else {
            NotificationCenter.default.post(name: .proPaywallRequested, object: nil)
            return
        }

        errorMessage = nil

        let userBubble = Message(id: UUID().uuidString, role: .user, content: text)
        messages.append(userBubble)

        let assistantBubble = Message(id: UUID().uuidString, role: .assistant, content: "")
        messages.append(assistantBubble)
        let assistantID = assistantBubble.id

        isStreaming = true
        let shouldIncludeDoc = !includedDocOnce && includeDocumentContext
        if shouldIncludeDoc { includedDocOnce = true }

        streamingTask = Task { @MainActor [weak self] in
            guard let self else { return }
            // First turn with the toggle on: hop to the bridge for the doc
            // markdown. Bubble still shows plain user text; the wire user
            // message carries the document context.
            let wireUserContent: String
            if shouldIncludeDoc {
                let docMarkdown = await self.bridge.getDocumentMarkdown()
                wireUserContent = self.wireUserMessage(prefixingDocContext: docMarkdown, userText: text)
            } else {
                wireUserContent = text
            }
            self.wireTranscript.append((role: "user", content: wireUserContent))
            let messagesToSend = self.wireTranscript

            await AIService.shared.runStreamingRequest(
                userPrompt: "",
                selectedMarkdown: "",
                contextBefore: "",
                contextAfter: "",
                messages: messagesToSend,
                systemPrompt: Self.chatSystemPrompt,
                onDelta: { [weak self] chunk in
                    self?.appendDelta(chunk, toAssistantID: assistantID)
                },
                onComplete: { [weak self] result in
                    self?.finishStream(result: result, assistantID: assistantID)
                }
            )
        }
    }

    func abort() {
        streamingTask?.cancel()
        streamingTask = nil
        discardPendingDelta()
        isStreaming = false
    }

    func clear() {
        abort()
        messages.removeAll()
        wireTranscript.removeAll()
        includedDocOnce = false
        errorMessage = nil
        flushPendingPersist()
        AgentChatStore.clear(for: currentDocumentURL)
    }

    /// Inserts a single Insertable Block's content at the BlockNote cursor.
    /// Callers pass the block's body verbatim (no fence markers); the editor
    /// bridge parses it as markdown.
    func insertBlockAtCursor(_ content: String) {
        bridge.insertMarkdownAtCursor(content)
    }

    // MARK: - Streaming callbacks

    private func appendDelta(_ chunk: String, toAssistantID id: String) {
        pendingDeltaBuffer += chunk
        pendingDeltaTargetID = id
        if deltaFlushTask == nil {
            deltaFlushTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: Self.deltaFlushInterval)
                self?.flushPendingDelta()
            }
        }
    }

    /// Drains `pendingDeltaBuffer` into the target assistant bubble. Called
    /// on the flush timer, and synchronously from `finishStream` so the final
    /// partial buffer always lands before the bubble switches to its settled
    /// (markdown-rendered) state.
    private func flushPendingDelta() {
        deltaFlushTask?.cancel()
        deltaFlushTask = nil
        let buffered = pendingDeltaBuffer
        let id = pendingDeltaTargetID
        pendingDeltaBuffer = ""
        pendingDeltaTargetID = nil
        guard !buffered.isEmpty,
              let id,
              let idx = messages.lastIndex(where: { $0.id == id }) else { return }
        messages[idx].content += buffered
    }

    /// Drops any pending delta without applying it. Used by `abort()` and
    /// `bind(to:)` — when the user hits Stop or switches documents we don't
    /// want a buffered chunk to silently land in the bubble after the fact.
    private func discardPendingDelta() {
        deltaFlushTask?.cancel()
        deltaFlushTask = nil
        pendingDeltaBuffer = ""
        pendingDeltaTargetID = nil
    }

    private func finishStream(result: Result<Void, AIError>, assistantID: String) {
        // Land the final buffered tokens BEFORE flipping `isStreaming` so the
        // bubble's content is complete the moment it switches to its settled
        // (markdown-rendered) state. Reversing the order leaves a one-frame
        // gap where the bubble renders the previous chunk in markdown mode
        // and only then catches the final fragment.
        flushPendingDelta()
        isStreaming = false
        streamingTask = nil
        switch result {
        case .success:
            if let idx = messages.firstIndex(where: { $0.id == assistantID }) {
                wireTranscript.append((role: "assistant", content: messages[idx].content))
            }
            schedulePersist()
        case .failure(let err):
            errorMessage = err.userMessage
            // Drop the (now-empty or partial) assistant bubble so the user
            // isn't left looking at a blank bubble for a failed request.
            if let idx = messages.lastIndex(where: { $0.id == assistantID }) {
                messages.remove(at: idx)
            }
            // Also pop the wire user turn that produced the failure so the
            // next attempt isn't replayed against a stale failed context.
            if let last = wireTranscript.last, last.role == "user" {
                wireTranscript.removeLast()
            }
            schedulePersist()
        }
    }

    // MARK: - Persistence

    private func schedulePersist() {
        persistTask?.cancel()
        let snapshot = messages
        let url = currentDocumentURL
        persistTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            let persisted = snapshot.map {
                AgentChatStore.PersistedMessage(id: $0.id, role: $0.role.rawValue, content: $0.content)
            }
            AgentChatStore.save(persisted, for: url)
        }
    }

    private func flushPendingPersist() {
        guard let persistTask else { return }
        persistTask.cancel()
        self.persistTask = nil
        let persisted = messages.map {
            AgentChatStore.PersistedMessage(id: $0.id, role: $0.role.rawValue, content: $0.content)
        }
        AgentChatStore.save(persisted, for: currentDocumentURL)
    }

    // MARK: - Doc context helper

    private func wireUserMessage(prefixingDocContext doc: String, userText: String) -> String {
        let trimmed = doc.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return userText }
        return """
            The user is working on the following Markdown document. Use it as background context when answering — do not echo it back verbatim.

            <document>
            \(trimmed)
            </document>

            User question:
            \(userText)
            """
    }
}
