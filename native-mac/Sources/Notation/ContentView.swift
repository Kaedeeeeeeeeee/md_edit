import SwiftUI
import AppKit

struct ContentView: View {
    @Environment(AppModel.self) private var store
    @Environment(AgentChatController.self) private var agentChat
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var didSetInitialVisibility = false

    var body: some View {
        // Onboarding gate: if no workspace has been adopted yet (first launch,
        // or saved bookmark unresolvable), show OnboardingView in place of
        // the editor.  Adopting a workspace flips `folderURL` and re-renders
        // into the NavigationSplitView path.
        if store.workspace.folderURL == nil {
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
                    if store.document.localImageAuthNeeded {
                        LocalImageAccessBanner(
                            onAllow: { store.document.authorizeCurrentDocumentFolder() },
                            onDismiss: {
                                withAnimation(.easeOut(duration: 0.18)) {
                                    store.document.localImageAuthNeeded = false
                                }
                            }
                        )
                        .padding(.top, 50)
                        .padding(.horizontal, 16)
                        .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
                .animation(.easeOut(duration: 0.2), value: store.document.localImageAuthNeeded)
                .overlay(alignment: .bottomTrailing) {
                    AgentOverlay()
                }
                .navigationTitle(documentTitle)
                .navigationSubtitle(folderTitle)
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            store.document.save()
                        } label: {
                            Label("Save", systemImage: "arrow.down.document")
                        }
                        .keyboardShortcut("s")
                        .disabled(!store.document.isDirty && store.document.currentFileURL != nil)
                        .help(store.document.isDirty ? Text("Save (⌘S)") : Text("No unsaved changes"))
                    }
                }
        }
        .navigationSplitViewStyle(.balanced)
        // EditorWebView reads the document as its own environment value so
        // the same view can back document windows with a different session.
        .environment(store.document)
        // Publish this window's document session for menu-command routing
        // (⌘S / ⌘⇧S / ⌘N resolve against the key window's session).
        .focusedSceneValue(\.documentSession, store.document)
        .onAppear {
            syncDocumentEditedDot(store.document.isDirty)
            // On first appearance, hide the sidebar if we opened straight to
            // a single file (Finder "Open With" or `open foo.md`).  When the
            // user is inside a workspace, sidebar stays at its default `.all`.
            guard !didSetInitialVisibility else { return }
            didSetInitialVisibility = true
            // Now that onboarding always provides a workspace, the only way
            // currentFileURL would be set with no fileTree entries is if the
            // user opened an external file outside the vault — keep their
            // focus on that file.
            if let url = store.document.currentFileURL,
               let folder = store.workspace.folderURL,
               !url.path.hasPrefix(folder.path) {
                columnVisibility = .detailOnly
            }
            agentChat.bind(to: store.document.currentFileURL)
        }
        .onChange(of: store.document.currentFileURL) { _, newURL in
            // Re-hydrate the per-document chat history whenever the open
            // document changes (workspace navigation, recent file, etc).
            agentChat.bind(to: newURL)
        }
        .onChange(of: store.document.isDirty) { _, dirty in
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
        let name = store.document.currentFileURL?.deletingPathExtension().lastPathComponent ?? "Untitled"
        return store.document.isDirty ? "● \(name)" : name
    }

    private var folderTitle: String {
        store.workspace.folderURL?.lastPathComponent ?? ""
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

// LocalImageAccessBanner moved to DocumentWindowView.swift — after phase-2
// routing only document windows host files outside authorised roots.  The
// overlay above still references it until the routing lands (phase 2.3
// removes the main-window usage).
