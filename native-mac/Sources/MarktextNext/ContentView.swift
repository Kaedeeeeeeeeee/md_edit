import SwiftUI

struct ContentView: View {
    @Environment(DocumentStore.self) private var store
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView()
        } detail: {
            EditorWebView()
                .ignoresSafeArea(edges: .top)
                .overlay(alignment: .top) {
                    TitleBarScrollEdge()
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
                        .help(store.isDirty ? "Save (⌘S)" : "No unsaved changes")
                    }
                }
        }
        .navigationSplitViewStyle(.balanced)
    }

    private var documentTitle: String {
        let name = store.currentFileURL?.deletingPathExtension().lastPathComponent ?? "Untitled"
        return store.isDirty ? "● \(name)" : name
    }

    private var folderTitle: String {
        store.folderURL?.lastPathComponent ?? ""
    }
}

/// Translucent fade sitting just below the title bar so editor content
/// scrolling up against the title doesn't collide with it visually.
/// Matches the macOS "scroll edge effect" used by Notes / Mail / Safari:
/// a native material at the top fading to clear ~56 px down.
private struct TitleBarScrollEdge: View {
    var body: some View {
        Rectangle()
            .fill(.regularMaterial)
            .frame(height: 56)
            .mask(
                LinearGradient(
                    stops: [
                        .init(color: .black, location: 0),
                        .init(color: .black, location: 0.55),
                        .init(color: .clear, location: 1)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .allowsHitTesting(false)
            .ignoresSafeArea(edges: .top)
    }
}
