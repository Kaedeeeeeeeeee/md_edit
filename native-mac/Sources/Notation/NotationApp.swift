import SwiftUI

@main
struct NotationApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store: DocumentStore
    @State private var closeGuard: CloseGuard?
    @State private var didAttachDelegate = false
    @State private var recentURLs: [URL] = RecentFiles.shared.urls

    init() {
        let store = DocumentStore()
        _store = State(initialValue: store)
        appDelegate.attach(store: store)
    }

    var body: some Scene {
        Window("Notation", id: "main") {
            ContentView()
                .environment(store)
                .frame(minWidth: 800, minHeight: 520)
                .background(
                    WindowAccessor { window in
                        let guardian = closeGuard ?? CloseGuard(store: store)
                        guardian.attach(to: window)
                        closeGuard = guardian
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
/// `orderOut`'d) can find their way home.  Also opens the main window if
/// AppDelegate posts `openMainRequested` from a cold-launch URL routing
/// path that needs SwiftUI rather than AppKit to construct the window.
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
/// `DocumentStore` via AppDelegate so security-scoped access and main-
/// window presentation are handled uniformly across cold-launch and warm
/// paths.
///
/// `store` is injected explicitly rather than read from `@Environment`
/// because this modifier is applied *outside* the `.environment(store)`
/// call on the scene's root view — an `@Environment(DocumentStore.self)`
/// here would trap during view setup because the value isn't in scope yet.
private struct OpenURLForwarder: ViewModifier {
    let store: DocumentStore
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content.onOpenURL { url in
            if let delegate = NSApp.delegate as? AppDelegate {
                delegate.openDocument(at: url)
            } else {
                // Fallback for preview/test contexts without the AppKit delegate.
                let needsScope = url.startAccessingSecurityScopedResource()
                defer { if needsScope { url.stopAccessingSecurityScopedResource() } }
                store.loadFile(url)
                openWindow(id: "main")
            }
        }
    }
}
