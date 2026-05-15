import SwiftUI

/// The floating Liquid Glass chat card. Three rows: header (title + actions),
/// scrollable message list, composer. Sized to sit just above the FAB at the
/// bottom-right; height clamps to the available vertical space so we never
/// outgrow the editor area.
struct AgentCard: View {
    @Bindable var controller: AgentChatController
    @State private var draft: String = ""
    @FocusState private var composerFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)
            messageList
            Divider().opacity(0.5)
            composer
        }
        .frame(width: 380)
        .frame(maxHeight: 560)
        .clipShape(.rect(cornerRadius: 20))
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .strokeBorder(Color.white.opacity(0.16), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.18), radius: 24, x: 0, y: 10)
        .shadow(color: .black.opacity(0.08), radius: 4, x: 0, y: 2)
        .onAppear { composerFocused = true }
    }

    // MARK: - Sections

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.tint)
            Text("AI Assistant")
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            Button {
                controller.clear()
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.plain)
            .frame(width: 26, height: 26)
            .contentShape(Rectangle())
            .help("Clear chat")
            .disabled(controller.messages.isEmpty && controller.errorMessage == nil)

            Button {
                controller.isOpen = false
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.plain)
            .frame(width: 26, height: 26)
            .contentShape(Rectangle())
            .help("Close (⌘⇧J)")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var messageList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                if controller.messages.isEmpty {
                    emptyState
                        .frame(maxWidth: .infinity)
                        .padding(.top, 36)
                        .padding(.horizontal, 24)
                } else {
                    ForEach(controller.messages) { msg in
                        AgentMessageBubble(
                            message: msg,
                            isStreaming: isMessageStreaming(msg),
                            onInsertBlock: { content in controller.insertBlockAtCursor(content) }
                        )
                        .id(msg.id)
                    }
                }
                if let error = controller.errorMessage {
                    Text(error)
                        .font(.system(size: 12))
                        .foregroundStyle(.red)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.red.opacity(0.1))
                        .clipShape(.rect(cornerRadius: 8))
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
        // The chat scrolls bottom-first: the bottom edge of the content stays
        // pinned to the viewport bottom when content grows. While streaming,
        // the bubble's height grows on every flush and the viewport sticks
        // to the bottom automatically — no manual `scrollTo` per delta, so
        // nothing fights the user's scroll gesture if they drag up to read.
        // Once the user scrolls away from the bottom, defaultScrollAnchor
        // anchors at whatever they're looking at instead of yanking them
        // back down.
        .defaultScrollAnchor(.bottom)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.system(size: 26))
                .foregroundStyle(.secondary)
                .opacity(0.6)
            Text("Ask anything about this document")
                .font(.system(size: 13, weight: .semibold))
                .multilineTextAlignment(.center)
            Text("Try \"Summarize this\", \"What are the key points?\", or \"Help me write an intro about…\"")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: $controller.includeDocumentContext) {
                Text("Include current doc as context")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .toggleStyle(.checkbox)
            .controlSize(.small)

            HStack(alignment: .bottom, spacing: 8) {
                TextField("Ask AI… (⌘+Enter to send)", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...6)
                    .focused($composerFocused)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(Color.primary.opacity(0.06))
                    .clipShape(.rect(cornerRadius: 10))
                    .onSubmit(of: .text) { trySend() }
                    .onKeyPress(.return, phases: .down) { press in
                        if press.modifiers.contains(.command) {
                            trySend()
                            return .handled
                        }
                        return .ignored
                    }

                sendOrStopButton
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }

    @ViewBuilder
    private var sendOrStopButton: some View {
        if controller.isStreaming {
            Button {
                controller.abort()
            } label: {
                Image(systemName: "stop.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(Color.red.opacity(0.9))
                    .clipShape(.rect(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .help("Stop")
        } else {
            Button {
                trySend()
            } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(canSend ? Color.accentColor : Color.accentColor.opacity(0.35))
                    .clipShape(.rect(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .help("Send")
        }
    }

    // MARK: - Helpers

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func trySend() {
        guard canSend, !controller.isStreaming else { return }
        let text = draft
        draft = ""
        controller.send(text)
    }

    /// The last assistant message is the one currently being streamed when
    /// `isStreaming` is on. We tag it so its bubble suppresses the action row
    /// (Insert / Replace) until the response is complete.
    private func isMessageStreaming(_ msg: AgentChatController.Message) -> Bool {
        controller.isStreaming
            && msg.role == .assistant
            && msg.id == controller.messages.last?.id
    }
}
