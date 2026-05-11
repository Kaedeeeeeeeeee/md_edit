import AppKit
import SwiftUI

/// AppKit delegate that supplements SwiftUI's scene-based URL routing.
///
/// SwiftUI's `.onOpenURL` and `.handlesExternalEvents(matching:)` work
/// reliably when the app launches in response to a file URL or when a
/// scene is already on screen.  They do NOT reliably re-activate a
/// dismissed `Window` scene when the app is running in the background
/// with no visible windows — that case lands here.
///
/// `application(_:open:)` is called by AppKit *every* time the user opens
/// a file with us (cold launch, double-click while running, drag onto
/// dock icon, command-line `open foo.md`).  We capture the URL, push it
/// through the shared `DocumentStore`, and force the main window back
/// on screen.  `CloseGuard` keeps the main window in memory after the
/// red close button is pressed, so the `NSApp.windows` lookup below
/// finds the same window we previously hid — its SwiftUI state, its
/// editor WebView, and its observers are all still wired up.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Latched from the App scene at startup so `application(_:open:)` can
    /// reach the document store without going through SwiftUI environment.
    weak var store: DocumentStore?

    /// URLs that arrived before `store` was wired up (e.g., cold launch).
    /// Drained from `MarktextNextApp` once the store is attached.
    var pendingURLs: [URL] = []

    func application(_ application: NSApplication, open urls: [URL]) {
        DebugLog.write("[appdelegate] open \(urls.count) URLs")
        for url in urls {
            if let store {
                deliverURL(url, to: store)
            } else {
                pendingURLs.append(url)
            }
        }
    }

    /// Called when the user clicks the Dock icon and the app is running.
    /// We deliberately do NOT bring back the hidden main editor window
    /// here — the standard IDE behaviour (Xcode / VS Code / JetBrains) is
    /// to re-show the workspace picker so the user can choose what to
    /// open next, even if their previous workspace is still in memory.
    /// Returning false suppresses AppKit's default reopen; we ask a live
    /// SwiftUI scene to call `openWindow(id: "picker")` via notification.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if hasVisibleWindows { return true }
        NSApp.activate(ignoringOtherApps: true)
        NotificationCenter.default.post(name: .openPickerRequested, object: nil)
        return false
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

    private func deliverURL(_ url: URL, to store: DocumentStore) {
        let needsScope = url.startAccessingSecurityScopedResource()
        defer { if needsScope { url.stopAccessingSecurityScopedResource() } }
        store.loadFile(url)
        showMainWindow()
    }

    /// Ask SwiftUI to (re)present the main editor window.  Going through
    /// `openWindow(id:)` rather than poking `NSApp.windows` manually means
    /// SwiftUI handles all the Window-scene lifecycle correctly — bringing
    /// a hidden main scene back to front, creating it if it never existed,
    /// AND closing the picker in the same notification handler.  Trying to
    /// find the main window ourselves via NSApp's window list was leaving
    /// the picker visible on top of (or in front of) the freshly-revealed
    /// main window, so the user just saw the picker and thought nothing
    /// had opened.
    private func showMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        NotificationCenter.default.post(name: .openMainRequested, object: nil)
    }
}

extension Notification.Name {
    /// Posted by `AppDelegate` when it has a URL to open but can't find an
    /// existing main NSWindow — any SwiftUI scene that's currently alive
    /// can observe this and call `openWindow(id: "main")` to bring it up.
    static let openMainRequested = Notification.Name("com.marktext.next.openMainRequested")

    /// Posted by `AppDelegate` on Dock-icon-click-with-no-visible-windows.
    /// Live SwiftUI scenes observe this and call `openWindow(id: "picker")`.
    static let openPickerRequested = Notification.Name("com.marktext.next.openPickerRequested")
}
