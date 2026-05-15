import SwiftUI

@main
struct MarktextNextApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store = DocumentStore()
    @State private var closeGuard: CloseGuard?
    @State private var didAttachDelegate = false
    @State private var recentURLs: [URL] = RecentFiles.shared.urls

    var body: some Scene {
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
                        (NSApp.delegate as? AppDelegate)?.registerMainWindow(window)
                    }
                )
                .onChange(of: store.currentFileURL) { _, _ in
                    recentURLs = RecentFiles.shared.urls
                }
                .modifier(OpenURLForwarder(store: store))
                .modifier(AppDelegateAttacher(store: store, didAttach: $didAttachDelegate))
        }
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

/// Hands the shared `DocumentStore` to `AppDelegate` so file-open events
/// arriving via AppKit (when the SwiftUI scene's NSWindow has been
/// `orderOut`'d) can find their way home.  Also drains any URLs that
/// arrived before onboarding completed.
private struct AppDelegateAttacher: ViewModifier {
    let store: DocumentStore
    @Binding var didAttach: Bool
    @Environment(\.openWindow) private var openWindow

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
            }
    }
}

/// Routes a file URL delivered to the scene (from Finder "Open With", a
/// double-click on a `.md`, or a drop on the dock icon) into the shared
/// `DocumentStore`.  Attached to the main editor scene.
///
/// `store` is injected explicitly rather than read from `@Environment`
/// because this modifier is applied *outside* the `.environment(store)`
/// call on the scene's root view — an `@Environment(DocumentStore.self)`
/// here would trap during view setup because the value isn't in scope yet.
private struct OpenURLForwarder: ViewModifier {
    let store: DocumentStore

    func body(content: Content) -> some View {
        content.onOpenURL { url in
            // Sandbox: the URL coming from Finder open-with is granted to us
            // implicitly, but wrap in start/stop to be safe for cases where
            // the path is outside any explicitly-granted scope.
            let needsScope = url.startAccessingSecurityScopedResource()
            defer { if needsScope { url.stopAccessingSecurityScopedResource() } }
            store.loadFile(url)
        }
    }
}
