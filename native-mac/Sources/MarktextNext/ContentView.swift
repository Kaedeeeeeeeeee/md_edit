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
