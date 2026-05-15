import AppKit
import SwiftUI

/// AppKit delegate that supplements SwiftUI's scene-based URL routing.
///
/// SwiftUI's `.onOpenURL` and `.handlesExternalEvents(matching:)` work
/// reliably when the app launches in response to a file URL or when the
/// editor scene's NSWindow is currently on screen.  They do NOT reliably
/// re-activate a window whose NSWindow was `orderOut`'d by `CloseGuard`
/// in response to the user pressing the red close button — that case
/// lands here.
///
/// `application(_:open:)` is called by AppKit *every* time the user opens
/// a file with us (cold launch, double-click while running, drag onto
/// dock icon, command-line `open foo.md`).  We capture the URL, push it
/// through the shared `DocumentStore`, and force the main window back on
/// screen via direct AppKit (`makeKeyAndOrderFront`).  SwiftUI's
/// `openWindow(id:)` is unreliable against an `orderOut`'d ghost window.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Latched from the App scene at startup so `application(_:open:)` can
    /// reach the document store without going through SwiftUI environment.
    weak var store: DocumentStore?

    /// Direct NSWindow ref registered by the main scene's `WindowAccessor`
    /// when SwiftUI first instantiates the underlying `NSWindow`.  Used for
    /// reliable show/hide via AppKit, independent of SwiftUI scene state.
    /// Not weak because the AppKit-fallback `createMainWindow` path is the
    /// sole owner in that branch and SwiftUI doesn't retain it for us.
    var mainWindow: NSWindow?

    /// URLs that arrived before `store` was wired up (e.g., cold launch).
    /// Drained from `NotationApp` once the store is attached.
    var pendingURLs: [URL] = []

    private var appKitMainCloseGuard: CloseGuard?

    func application(_ application: NSApplication, open urls: [URL]) {
        DebugLog.write("[appdelegate] open \(urls.count) URLs")
        openDocuments(at: urls)
    }

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        DebugLog.write("[appdelegate] openFile \(filename)")
        openDocument(at: URL(fileURLWithPath: filename))
        return true
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        DebugLog.write("[appdelegate] openFiles \(filenames.count) files")
        openDocuments(at: filenames.map { URL(fileURLWithPath: $0) })
        sender.reply(toOpenOrPrint: .success)
    }

    func openDocument(at url: URL) {
        openDocuments(at: [url])
    }

    /// Dock-icon click with no visible windows: bring the (hidden) main
    /// window back to the front.  Onboarding is owned by `ContentView`'s
    /// body gate, so we don't need any picker plumbing here.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if hasVisibleWindows { return true }
        NSApp.activate(ignoringOtherApps: true)
        if let mainWindow = mainWindow ?? findWindow(identifier: .notationMainWindow) {
            self.mainWindow = mainWindow
            mainWindow.makeKeyAndOrderFront(nil)
            return false
        }
        // Cold path: SwiftUI scene hasn't instantiated its NSWindow yet.
        // Ask any live SwiftUI listener to open it via the standard action.
        NotificationCenter.default.post(name: .openMainRequested, object: nil)
        return false
    }

    // MARK: - Window registration

    func registerMainWindow(_ window: NSWindow) {
        window.identifier = .notationMainWindow
        window.isReleasedWhenClosed = false
        mainWindow = window
    }

    /// Called from the App scene after `@State store` is constructed.
    func attach(store: DocumentStore) {
        self.store = store
        if !pendingURLs.isEmpty {
            let drained = pendingURLs
            pendingURLs.removeAll()
            for url in drained {
                deliverURL(url, to: store)
            }
        }
    }

    // MARK: - Internals

    private func openDocuments(at urls: [URL]) {
        for url in urls {
            if let store {
                deliverURL(url, to: store)
            } else {
                pendingURLs.append(url)
            }
        }
    }

    private func deliverURL(_ url: URL, to store: DocumentStore) {
        let needsScope = url.startAccessingSecurityScopedResource()
        defer { if needsScope { url.stopAccessingSecurityScopedResource() } }
        store.loadFile(url)
        presentMainWindow()
    }

    /// Bring the main editor window to the front via direct AppKit calls.
    /// If SwiftUI hasn't constructed its NSWindow yet (cold-launch via Finder
    /// open-with), construct one directly via AppKit so the user's file
    /// shows up immediately rather than racing the scene lifecycle.
    private func presentMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if let mainWindow = mainWindow ?? findWindow(identifier: .notationMainWindow) {
            self.mainWindow = mainWindow
            mainWindow.makeKeyAndOrderFront(nil)
            return
        }

        if let store {
            let window = createMainWindow(store: store)
            window.makeKeyAndOrderFront(nil)
            return
        }

        NotificationCenter.default.post(name: .openMainRequested, object: nil)
    }

    private func findWindow(identifier: NSUserInterfaceItemIdentifier) -> NSWindow? {
        NSApp.windows.first { $0.identifier == identifier }
    }

    private func createMainWindow(store: DocumentStore) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1088, height: 714),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Notation"
        window.identifier = .notationMainWindow
        window.minSize = NSSize(width: 800, height: 520)
        window.toolbarStyle = .unified
        window.contentView = NSHostingView(
            rootView: ContentView()
                .environment(store)
                .frame(minWidth: 800, minHeight: 520)
        )

        let guardian = CloseGuard(store: store)
        guardian.attach(to: window)
        appKitMainCloseGuard = guardian
        mainWindow = window
        window.center()
        return window
    }
}

private extension NSUserInterfaceItemIdentifier {
    static let notationMainWindow = NSUserInterfaceItemIdentifier("com.notation.window.main")
}

extension Notification.Name {
    /// Posted by `AppDelegate` when it has a URL to open but can't find an
    /// existing main NSWindow — any SwiftUI scene that's currently alive
    /// can observe this and call `openWindow(id: "main")` to bring it up.
    static let openMainRequested = Notification.Name("com.notation.openMainRequested")
}
