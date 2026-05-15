import SwiftUI

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
        .onReceive(NotificationCenter.default.publisher(for: .aiAgentToggleRequested)) { _ in
            agentChat.toggle()
        }
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
