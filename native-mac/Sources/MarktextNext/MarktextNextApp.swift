import SwiftUI

@main
struct MarktextNextApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store = DocumentStore()
    @State private var closeGuard: CloseGuard?
    @State private var didAttachDelegate = false
    @State private var recentURLs: [URL] = RecentFiles.shared.urls
    @State private var recentFolders: [(url: URL, displayName: String)] =
        WorkspaceBookmark.recentWorkspaces()

    var body: some Scene {
        // Launch-time workspace picker (Xcode "Welcome to Xcode" style).
        // Shown by default; the main editor scene is suppressed until the
        // picker chooses a workspace and explicitly opens it.
        Window("Open Workspace", id: "picker") {
            WorkspacePicker()
                .environment(store)
                .modifier(OpenURLForwarder(store: store))
                .modifier(AppDelegateAttacher(store: store, didAttach: $didAttachDelegate))
        }
        .defaultLaunchBehavior(.presented)
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)

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
                .modifier(OpenURLForwarder(store: store))
                .modifier(AppDelegateAttacher(store: store, didAttach: $didAttachDelegate))
        }
        .defaultLaunchBehavior(.suppressed)
        .handlesExternalEvents(matching: ["*"])
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

/// Hands the shared `DocumentStore` to `AppDelegate` so file-open events
/// arriving via AppKit (when no SwiftUI scene is on screen) can find their
/// way home.  Also listens for `openMainRequested` notifications and
/// fulfils them by opening the main scene window.
private struct AppDelegateAttacher: ViewModifier {
    let store: DocumentStore
    @Binding var didAttach: Bool
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    func body(content: Content) -> some View {
        content
            .onAppear {
                if !didAttach {
                    didAttach = true
                    if let delegate = NSApp.delegate as? AppDelegate {
                        delegate.attach(store: store)
                    }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .openMainRequested)) { _ in
                openWindow(id: "main")
                dismissWindow(id: "picker")
            }
    }
}

/// Routes a file URL delivered to the scene (from Finder "Open With", a
/// double-click on a `.md`, or a drop on the dock icon) into the shared
/// `DocumentStore`, opens the main editor window, and dismisses the picker
/// if it was still up.  Attached to both the picker and main scenes so
/// the URL gets handled regardless of which is foremost when it arrives.
///
/// `store` is injected explicitly rather than read from `@Environment`
/// because this modifier is applied *outside* the `.environment(store)`
/// call on each scene's root view — an `@Environment(DocumentStore.self)`
/// here would trap during view setup because the value isn't in scope yet.
private struct OpenURLForwarder: ViewModifier {
    let store: DocumentStore
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    func body(content: Content) -> some View {
        content.onOpenURL { url in
            // Sandbox: the URL coming from Finder open-with is granted to us
            // implicitly, but wrap in start/stop to be safe for cases where
            // the path is outside any explicitly-granted scope.
            let needsScope = url.startAccessingSecurityScopedResource()
            defer { if needsScope { url.stopAccessingSecurityScopedResource() } }
            store.loadFile(url)
            openWindow(id: "main")
            dismissWindow(id: "picker")
        }
    }
}
