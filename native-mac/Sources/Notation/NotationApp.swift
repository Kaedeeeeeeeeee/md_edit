import SwiftUI
import AppKit

/// Focused-window plumbing for menu commands (B2 refactor, phase 1.5).
///
/// Each editor window's root view publishes its DocumentSession via
/// `.focusedSceneValue(\.documentSession, ...)`; document-targeting
/// commands read `@FocusedValue(\.documentSession)` so ⌘S / ⌘⇧S / ⌘N
/// act on whichever window is key.  Today there is exactly one editor
/// window, so the focused value either equals the main session or is
/// nil (no key window — e.g. Settings is frontmost); callers fall back
/// to the main session, preserving current behavior.  Phase 2's
/// document windows publish their own sessions and the same commands
/// route correctly with no further changes.
extension FocusedValues {
    @Entry var documentSession: DocumentSession?
}

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
    @State private var store: AppModel
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
        let store = AppModel()
        _store = State(initialValue: store)
        let bridge = EditorJSBridge()
        _editorBridge = State(initialValue: bridge)
        _agentChat = State(initialValue: AgentChatController(bridge: bridge))
        let paywall = PaywallStore()
        _paywallStore = State(initialValue: paywall)
        // Wire the document-window factory: external files open in AppKit
        // NSWindows (see DocumentWindowManager), and window construction
        // needs these app-level environment objects.
        store.documentWindows.makeWindow = { url, session in
            DocumentWindowHost.makeWindow(
                fileURL: url, session: session, store: store, paywall: paywall
            )
        }
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
                        let guardian = closeGuard ?? CloseGuard(document: store.document)
                        guardian.attach(to: window)
                        closeGuard = guardian
                        AppDelegate.shared?.registerMainWindow(window)
                    }
                )
                .onChange(of: store.document.currentFileURL) { _, _ in
                    recentURLs = RecentFiles.shared.urls
                }
                .onChange(of: store.workspace.folderURL) { _, _ in
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
                .onChange(of: showPaywall) { _, newValue in
                    // Keep PaywallStore in sync so AgentOverlay can collapse
                    // the FAB while the sheet is up.  The FAB's interactive
                    // glassEffect occludes Xcode's local StoreKit Testing
                    // confirmation button on cursor hover.
                    paywallStore.isPaywallVisible = newValue
                }
        }
        // Claim external events so a cold-launch file open materialises
        // this scene with its full environment chain — the main window
        // presents normally, and `application(_:open:)` routes the file to
        // AppModel.openDocument.  Since document windows are AppKit (no URL
        // WindowGroup), SwiftUI's routing never closes this window.
        .handlesExternalEvents(matching: ["*"])
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        // First-launch window size.  Stored frame from previous sessions
        // (set by the SwiftUI scene's automatic frame persistence) wins
        // over this — so this only applies the very first time the user
        // opens the app or after they reset the saved frame.
        .defaultSize(width: 1200, height: 780)
        .commands {
            // Pro / subscription management items, near the top of the
            // application menu so they're easy to find.
            CommandGroup(after: .appInfo) {
                if !entitlement.isPro {
                    Button("Upgrade Notation…") {
                        NotificationCenter.default.post(name: .proPaywallRequested, object: nil)
                    }
                } else if entitlement.activeTier?.isSubscription == true {
                    Button("Manage Subscription…") {
                        if let url = URL(string: "https://apps.apple.com/account/subscriptions") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
                Button("Restore Purchases") {
                    Task { try? await paywallStore.restore() }
                }
                Divider()
            }

            FileCommands(
                store: store,
                recentURLs: $recentURLs,
                recentWorkspaces: $recentWorkspaces
            )

            // Forward the standard clipboard selectors to the first
            // responder (editor WKWebView, sidebar responder, or a focused
            // TextField).  SwiftUI's *default* Edit menu can't be used: it
            // gates Cut/Copy/Paste on its own focus model and leaves them
            // disabled for a WKWebView, and a disabled menu item swallows
            // ⌘C/⌘V before the web view ever sees them.  Always-enabled
            // forwarding commands sidestep that and route to whichever pane
            // holds key focus.
            CommandGroup(replacing: .pasteboard) {
                Button("Cut") { NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: nil) }
                    .keyboardShortcut("x")
                Button("Copy") { NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil) }
                    .keyboardShortcut("c")
                Button("Paste") { NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil) }
                    .keyboardShortcut("v")
                Button("Select All") { NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil) }
                    .keyboardShortcut("a")
            }

            CommandGroup(after: .windowList) {
                Divider()
                Button("Refresh File Tree") {
                    store.workspace.rebuildFileTree()
                }
                .keyboardShortcut("r")
                .disabled(store.workspace.folderURL == nil)
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

        // NOTE: external-file document windows are NOT a SwiftUI scene.
        // They're AppKit NSWindows built by DocumentWindowManager (see its
        // doc comment for why openWindow can't be used at cold launch).

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

/// File-menu commands.  Extracted into its own `Commands` type because
/// `@FocusedValue` only updates reliably inside a Commands conformance —
/// reading it from the App struct's body silently sticks to nil.
///
/// Document-targeting items (New / Open File / Recents / Save / Save As)
/// resolve against the focused window's session with a main-session
/// fallback; workspace-registry items (Open Folder / Switch Workspace)
/// always talk to the app-level store since there is exactly one
/// workspace regardless of which window is key.
private struct FileCommands: Commands {
    let store: AppModel
    @Binding var recentURLs: [URL]
    @Binding var recentWorkspaces: [(url: URL, displayName: String)]
    @FocusedValue(\.documentSession) private var focusedDocument

    private var activeDocument: DocumentSession {
        focusedDocument ?? store.document
    }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            // New is deliberately NOT focus-routed: a new note always
            // belongs to the workspace (untitled autosave needs a
            // workspace to land in), so ⌘N from a document window jumps
            // to the main window rather than blanking the external file.
            Button("New") {
                store.document.newDocument()
                AppDelegate.shared?.showMainWindow()
            }
            .keyboardShortcut("n")

            Divider()

            Button("Open Folder…") { store.openFolderDialog() }
                .keyboardShortcut("o")

            // Routed by workspace containment (main window vs document
            // window) — see AppModel.openDocument.
            Button("Open File…") { store.openFileDialog() }
                .keyboardShortcut("o", modifiers: [.command, .shift])

            Menu("Switch Workspace") {
                if recentWorkspaces.isEmpty {
                    Text("No saved workspaces")
                } else {
                    ForEach(recentWorkspaces, id: \.url.absoluteString) { entry in
                        Button {
                            guard entry.url != store.workspace.folderURL else { return }
                            store.adoptRecentWorkspace(entry.url)
                        } label: {
                            if entry.url == store.workspace.folderURL {
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
                            // Re-arm the sandbox grant from the stored
                            // bookmark before routing.  Ownership of the
                            // started scope transfers into openDocument.
                            if let started = RecentFiles.shared.beginAccess(matching: url) {
                                store.openDocument(at: started, heldScope: started)
                            } else {
                                // No resolvable bookmark — try the raw URL;
                                // workspace files don't need a scope.
                                store.openDocument(at: url)
                            }
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
            Button("Save") { activeDocument.save() }
                .keyboardShortcut("s")

            Button("Save As…") { activeDocument.saveAs() }
                .keyboardShortcut("s", modifiers: [.command, .shift])
        }
    }
}

/// Hands the shared `AppModel` to `AppDelegate` so file-open events
/// arriving via AppKit (when the SwiftUI scene's NSWindow has been
/// `orderOut`'d) can find their way home.  Also opens the main window if
/// AppDelegate posts `openMainRequested` from a cold-launch URL routing
/// path that needs SwiftUI rather than AppKit to construct the window.
private struct AppDelegateAttacher: ViewModifier {
    let store: AppModel
    @Binding var didAttach: Bool
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content
            .onAppear {
                if !didAttach {
                    didAttach = true
                    AppDelegate.shared?.attach(store: store)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .openMainRequested)) { _ in
                openWindow(id: "main")
            }
    }
}

/// Routes a file URL delivered to the scene (from Finder "Open With", a
/// double-click on a `.md`, or a drop on the dock icon) into the shared
/// `AppModel` via AppDelegate so security-scoped access and main-
/// window presentation are handled uniformly across cold-launch and warm
/// paths.
///
/// `store` is injected explicitly rather than read from `@Environment`
/// because this modifier is applied *outside* the `.environment(store)`
/// call on the scene's root view — an `@Environment(AppModel.self)`
/// here would trap during view setup because the value isn't in scope yet.
private struct OpenURLForwarder: ViewModifier {
    let store: AppModel
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content.onOpenURL { url in
            DebugLog.write("[onOpenURL] \(url.lastPathComponent)")
            if let delegate = AppDelegate.shared {
                delegate.openDocument(at: url)
            } else {
                // Fallback for preview/test contexts without the AppKit delegate.
                let needsScope = url.startAccessingSecurityScopedResource()
                defer { if needsScope { url.stopAccessingSecurityScopedResource() } }
                store.document.loadFile(url)
                openWindow(id: "main")
            }
        }
    }
}
