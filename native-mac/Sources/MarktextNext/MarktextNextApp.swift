import SwiftUI

@main
struct MarktextNextApp: App {
    @State private var store = DocumentStore()
    @State private var closeGuard: CloseGuard?
    @State private var recentURLs: [URL] = RecentFiles.shared.urls
    @State private var recentFolders: [(url: URL, displayName: String)] =
        WorkspaceBookmark.recentWorkspaces()

    var body: some Scene {
        // Launch-time workspace picker (VS Code-style).  Shown by default;
        // the main editor scene is suppressed until the picker chooses a
        // workspace and explicitly opens it.
        Window("Open Workspace", id: "picker") {
            WorkspacePicker()
                .environment(store)
        }
        .defaultLaunchBehavior(.presented)
        .windowResizability(.contentSize)
        .windowStyle(.titleBar)

        // Main editor window.  Singleton (so state restoration can't
        // multiply it into stale duplicates that race to own the WebView
        // bridge).  Opened by the picker via `openWindow(id: "main")`.
        Window("Marktext Next", id: "main") {
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
                .onChange(of: store.currentFileURL) { _, _ in
                    recentURLs = RecentFiles.shared.urls
                }
                .onChange(of: store.folderURL) { _, _ in
                    recentFolders = WorkspaceBookmark.recentWorkspaces()
                }
        }
        .defaultLaunchBehavior(.suppressed)
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New") { store.newDocument() }
                    .keyboardShortcut("n")

                Divider()

                Button("Open Folder…") { store.openFolderDialog() }
                    .keyboardShortcut("o")

                Button("Open File…") { store.openFileDialog() }
                    .keyboardShortcut("o", modifiers: [.command, .shift])

                SwitchWorkspaceMenuItem()

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

/// Tiny wrapper view so the "Switch Workspace…" menu item can pull
/// `openWindow` out of the environment — Scene-level `.commands` builders
/// don't see view environment values directly.
private struct SwitchWorkspaceMenuItem: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Switch Workspace…") {
            openWindow(id: "picker")
        }
        .keyboardShortcut("o", modifiers: [.command, .option])
    }
}
