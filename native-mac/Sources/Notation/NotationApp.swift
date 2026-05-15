import SwiftUI

extension Notification.Name {
    static let aiPageActionRequested = Notification.Name("aiPageActionRequested")
    static let aiAgentToggleRequested = Notification.Name("aiAgentToggleRequested")
    static let aiResearchRequested = Notification.Name("aiResearchRequested")
    /// Posted from anywhere when an AI action is attempted while the user
    /// is not Pro. The paywall sheet (mounted in the main editor window)
    /// listens for this and presents itself immediately, regardless of
    /// the cold-launch 24h cooldown.
    static let proPaywallRequested = Notification.Name("proPaywallRequested")
}

@main
struct NotationApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store: DocumentStore
    @State private var closeGuard: CloseGuard?
    @State private var didAttachDelegate = false
    @State private var recentURLs: [URL] = RecentFiles.shared.urls
    @State private var recentWorkspaces: [(url: URL, displayName: String)] = WorkspaceBookmark.recentWorkspaces()
    // Shared with EditorWebView so the WKWebView reference can be threaded in
    // when the view materializes. Owned at App-level so it survives across
    // editor remounts (e.g. workspace switch) and the chat controller can keep
    // pointing at it.
    @State private var editorBridge: EditorJSBridge
    @State private var agentChat: AgentChatController
    // Paywall infrastructure. `paywallStore` owns the StoreKit observer
    // task for the App's entire lifetime; `showPaywall` toggles the sheet
    // on the main editor window.
    @State private var paywallStore: PaywallStore
    @State private var showPaywall: Bool = false
    // Held as @State so SwiftUI re-renders Commands / menus when isPro flips
    // (e.g., after a successful purchase, "Upgrade…" hides and "Manage
    // Subscription" appears without requiring an app relaunch).
    @State private var entitlement: EntitlementState = EntitlementState.shared

    init() {
        let store = DocumentStore()
        _store = State(initialValue: store)
        let bridge = EditorJSBridge()
        _editorBridge = State(initialValue: bridge)
        _agentChat = State(initialValue: AgentChatController(bridge: bridge))
        _paywallStore = State(initialValue: PaywallStore())
        // All stored properties must be initialized before we can call into
        // `appDelegate` (using `self` is otherwise rejected).
        appDelegate.attach(store: store)
    }

    var body: some Scene {
        Window("Notation", id: "main") {
            ContentView()
                .environment(store)
                .environment(agentChat)
                .environment(paywallStore)
                .environment(EntitlementState.shared)
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
                .onChange(of: store.folderURL) { _, _ in
                    recentWorkspaces = WorkspaceBookmark.recentWorkspaces()
                }
                .modifier(OpenURLForwarder(store: store))
                .modifier(AppDelegateAttacher(store: store, didAttach: $didAttachDelegate))
                // Paywall mount: cold-launch trigger waits for StoreKit to
                // settle (initialize is idempotent) before deciding, so we
                // never flash the sheet to an already-Pro user.
                .task {
                    await paywallStore.initialize()
                    if PaywallTrigger.shouldShowOnLaunch() {
                        showPaywall = true
                    }
                }
                // Any AI gate failing posts this; opens the sheet immediately
                // regardless of the 24h cooldown (the explicit AI attempt is
                // the user's signal that they want to upgrade).
                .onReceive(NotificationCenter.default.publisher(for: .proPaywallRequested)) { _ in
                    showPaywall = true
                }
                .sheet(isPresented: $showPaywall) {
                    PaywallView()
                        .environment(paywallStore)
                        .environment(EntitlementState.shared)
                }
        }
        .handlesExternalEvents(matching: ["*"])
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .commands {
            // Pro / subscription management items, near the top of the
            // application menu so they're easy to find.
            CommandGroup(after: .appInfo) {
                if !entitlement.isPro {
                    Button("升级 Notation…") {
                        NotificationCenter.default.post(name: .proPaywallRequested, object: nil)
                    }
                } else if entitlement.activeTier?.isSubscription == true {
                    Button("管理订阅…") {
                        if let url = URL(string: "https://apps.apple.com/account/subscriptions") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
                Button("恢复购买") {
                    Task { try? await paywallStore.restore() }
                }
                Divider()
            }

            CommandGroup(replacing: .newItem) {
                Button("New") { store.newDocument() }
                    .keyboardShortcut("n")

                Divider()

                Button("Open Folder…") { store.openFolderDialog() }
                    .keyboardShortcut("o")

                Button("Open File…") { store.openFileDialog() }
                    .keyboardShortcut("o", modifiers: [.command, .shift])

                Menu("Switch Workspace") {
                    if recentWorkspaces.isEmpty {
                        Text("No saved workspaces")
                    } else {
                        ForEach(recentWorkspaces, id: \.url.absoluteString) { entry in
                            Button {
                                guard entry.url != store.folderURL else { return }
                                store.adoptRecentWorkspace(entry.url)
                            } label: {
                                if entry.url == store.folderURL {
                                    Label(entry.displayName, systemImage: "checkmark")
                                } else {
                                    Text(entry.displayName)
                                }
                            }
                        }
                        Divider()
                        Button("Add Folder as Workspace…") {
                            store.openFolderDialog()
                        }
                    }
                }
                .keyboardShortcut("o", modifiers: [.command, .option])

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

            CommandMenu("AI") {
                // Toggle Assistant is intentionally NOT gated — opening the
                // sidebar UI alone makes no AI call. The first send() inside
                // AgentChatController is where Pro is enforced.
                Button("Toggle AI Assistant") {
                    NotificationCenter.default.post(name: .aiAgentToggleRequested, object: nil)
                }
                .keyboardShortcut("j", modifiers: [.command, .shift])

                Divider()

                Button("Summarize Page") {
                    triggerPageAction("summarize")
                }
                .keyboardShortcut("s", modifiers: [.command, .shift, .option])

                Button("Translate Page…") {
                    triggerPageAction("translate")
                }

                Divider()

                Button("Research…") {
                    guard requireProOrShowPaywall() else { return }
                    NotificationCenter.default.post(name: .aiResearchRequested, object: nil)
                }
                .keyboardShortcut("r", modifiers: [.command, .shift, .option])
            }
        }

        Settings {
            SettingsView()
                .environment(EntitlementState.shared)
                .environment(paywallStore)
        }
    }

    private func triggerPageAction(_ action: String) {
        guard requireProOrShowPaywall() else { return }
        NotificationCenter.default.post(
            name: .aiPageActionRequested,
            object: nil,
            userInfo: ["action": action]
        )
    }

    /// Returns true if the user has Pro and the action should proceed.
    /// Returns false and posts `.proPaywallRequested` otherwise.
    /// Use as a guard at the top of every Pro-only action.
    @discardableResult
    private func requireProOrShowPaywall() -> Bool {
        if EntitlementState.shared.isPro { return true }
        NotificationCenter.default.post(name: .proPaywallRequested, object: nil)
        return false
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
