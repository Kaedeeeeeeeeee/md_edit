import SwiftUI
import AppKit

struct ContentView: View {
    @Environment(DocumentStore.self) private var store
    @Environment(AgentChatController.self) private var agentChat
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var didSetInitialVisibility = false

    var body: some View {
        // Onboarding gate: if no workspace has been adopted yet (first launch,
        // or saved bookmark unresolvable), show OnboardingView in place of
        // the editor.  Adopting a workspace flips `folderURL` and re-renders
        // into the NavigationSplitView path.
        if store.folderURL == nil {
            OnboardingView()
        } else {
            editor
        }
    }

    private var editor: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView()
        } detail: {
            EditorWebView()
                .ignoresSafeArea(edges: .top)
                .overlay(alignment: .top) {
                    TitleBarScrollEdge()
                }
                .overlay(alignment: .top) {
                    if store.localImageAuthNeeded {
                        LocalImageAccessBanner(
                            onAllow: { store.authorizeCurrentDocumentFolder() },
                            onDismiss: {
                                withAnimation(.easeOut(duration: 0.18)) {
                                    store.localImageAuthNeeded = false
                                }
                            }
                        )
                        .padding(.top, 50)
                        .padding(.horizontal, 16)
                        .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
                .animation(.easeOut(duration: 0.2), value: store.localImageAuthNeeded)
                .overlay(alignment: .bottomTrailing) {
                    AgentOverlay()
                }
                .navigationTitle(documentTitle)
                .navigationSubtitle(folderTitle)
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            store.save()
                        } label: {
                            Label("Save", systemImage: "arrow.down.document")
                        }
                        .keyboardShortcut("s")
                        .disabled(!store.isDirty && store.currentFileURL != nil)
                        .help(store.isDirty ? Text("Save (⌘S)") : Text("No unsaved changes"))
                    }
                }
        }
        .navigationSplitViewStyle(.balanced)
        .onAppear {
            syncDocumentEditedDot(store.isDirty)
            // On first appearance, hide the sidebar if we opened straight to
            // a single file (Finder "Open With" or `open foo.md`).  When the
            // user is inside a workspace, sidebar stays at its default `.all`.
            guard !didSetInitialVisibility else { return }
            didSetInitialVisibility = true
            // Now that onboarding always provides a workspace, the only way
            // currentFileURL would be set with no fileTree entries is if the
            // user opened an external file outside the vault — keep their
            // focus on that file.
            if let url = store.currentFileURL,
               let folder = store.folderURL,
               !url.path.hasPrefix(folder.path) {
                columnVisibility = .detailOnly
            }
            agentChat.bind(to: store.currentFileURL)
        }
        .onChange(of: store.currentFileURL) { _, newURL in
            // Re-hydrate the per-document chat history whenever the open
            // document changes (workspace navigation, recent file, etc).
            agentChat.bind(to: newURL)
        }
        .onChange(of: store.isDirty) { _, dirty in
            syncDocumentEditedDot(dirty)
        }
        .onReceive(NotificationCenter.default.publisher(for: .aiAgentToggleRequested)) { _ in
            agentChat.toggle()
        }
    }

    /// Mirror dirty state into the close button's system dot — the
    /// macOS-wide "unsaved document" convention (TextEdit, Pages).  The
    /// titlebar ● carries the same signal, but the close-button dot reads
    /// even when the title is truncated or the user glances at traffic
    /// lights only.
    private func syncDocumentEditedDot(_ dirty: Bool) {
        (NSApp.delegate as? AppDelegate)?.mainWindow?.isDocumentEdited = dirty
    }

    private var documentTitle: String {
        let name = store.currentFileURL?.deletingPathExtension().lastPathComponent ?? "Untitled"
        return store.isDirty ? "● \(name)" : name
    }

    private var folderTitle: String {
        store.folderURL?.lastPathComponent ?? ""
    }
}

/// Solid-colour fade sitting just below the title bar so editor content
/// scrolling up against the title doesn't collide with it visually.
/// Uses `NSColor.textBackgroundColor` so it matches the editor canvas
/// exactly — white in light mode, dark in dark mode — and reads as a
/// natural continuation of the editor instead of a translucent scrim.
private struct TitleBarScrollEdge: View {
    var body: some View {
        Color(nsColor: .textBackgroundColor)
            .frame(height: 56)
            .mask(
                LinearGradient(
                    colors: [.black, .clear],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .allowsHitTesting(false)
            .ignoresSafeArea(edges: .top)
    }
}

/// Non-blocking banner offering one-time folder access so a document opened
/// as a single file (outside the workspace) can display its local images.
/// The grant is remembered per directory tree, so this appears only once per
/// folder — matching the "other editors just show it after one OK" mental
/// model while staying inside the App Sandbox.
private struct LocalImageAccessBanner: View {
    let onAllow: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.title3)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text("This document references local images.")
                    .font(.callout)
                    .fontWeight(.medium)
                Text("Allow access to its folder so they can be displayed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            Button(action: onAllow) {
                Text("Allow Access…")
            }
            .controlSize(.small)
            .buttonStyle(.borderedProminent)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                    .padding(4)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(Text("Dismiss"))
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.12), radius: 10, y: 3)
        .frame(maxWidth: 540)
    }
}
