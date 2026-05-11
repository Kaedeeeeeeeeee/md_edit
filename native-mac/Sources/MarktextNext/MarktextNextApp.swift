import SwiftUI

@main
struct MarktextNextApp: App {
    @State private var store = DocumentStore()
    @State private var closeGuard: CloseGuard?
    @State private var recentURLs: [URL] = RecentFiles.shared.urls
    @State private var recentFolders: [(url: URL, displayName: String)] = WorkspaceBookmark.recentWorkspaces()
    @State private var didRestore = false

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(store)
                .frame(minWidth: 800, minHeight: 520)
                .background(
                    WindowAccessor { window in
                        if closeGuard == nil {
                            let guardian = CloseGuard(store: store)
                            guardian.attach(to: window)
                            closeGuard = guardian
                        }
                    }
                )
                .onAppear {
                    if !didRestore {
                        didRestore = true
                        store.restoreSavedWorkspaceIfAvailable()
                        recentFolders = WorkspaceBookmark.recentWorkspaces()
                    }
                }
                .onChange(of: store.currentFileURL) { _, _ in
                    recentURLs = RecentFiles.shared.urls
                }
                .onChange(of: store.folderURL) { _, _ in
                    recentFolders = WorkspaceBookmark.recentWorkspaces()
                }
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New") { store.newDocument() }
                    .keyboardShortcut("n")

                Divider()

                Button("Open File…") { store.openFileDialog() }
                    .keyboardShortcut("o")

                Button("Open Folder…") { store.openFolderDialog() }
                    .keyboardShortcut("o", modifiers: [.command, .shift])

                Menu("Open Recent Folder") {
                    if recentFolders.isEmpty {
                        Text("No recent folders")
                    } else {
                        ForEach(recentFolders, id: \.url.absoluteString) { item in
                            Button(item.displayName) {
                                store.adoptRecentWorkspace(item.url)
                            }
                        }
                        Divider()
                        Button("Clear Menu") {
                            WorkspaceBookmark.clearRecent()
                            recentFolders = []
                        }
                    }
                }

                Menu("Open Recent File") {
                    if recentURLs.isEmpty {
                        Text("No recent files")
                    } else {
                        ForEach(recentURLs, id: \.absoluteString) { url in
                            Button(url.lastPathComponent) {
                                store.loadFile(url)
                            }
                        }
                        Divider()
                        Button("Clear Menu") {
                            RecentFiles.shared.clear()
                            recentURLs = []
                        }
                    }
                }
            }

            CommandGroup(replacing: .saveItem) {
                Button("Save") { store.save() }
                    .keyboardShortcut("s")

                Button("Save As…") { store.saveAs() }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
            }

            CommandGroup(after: .windowList) {
                Divider()
                Button("Refresh File Tree") {
                    store.rebuildFileTree()
                }
                .keyboardShortcut("r")
                .disabled(store.folderURL == nil)
            }
        }

        Settings {
            SettingsView()
        }
    }
}
