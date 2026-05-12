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

    /// Direct NSWindow refs registered by each scene's `WindowAccessor` when
    /// SwiftUI first instantiates the underlying `NSWindow`.  We drive the
    /// "show / hide / bring-to-front" choreography via these refs instead
    /// of going through SwiftUI's `openWindow` / `dismissWindow` actions —
    /// the SwiftUI path doesn't reliably wake a Window scene whose
    /// NSWindow was `orderOut`'d (ghost-scene problem).  AppKit-level
    /// `makeKeyAndOrderFront` / `orderOut` are synchronous and unaffected.
    weak var mainWindow: NSWindow?
    weak var pickerWindow: NSWindow?

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
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if hasVisibleWindows { return true }
        NSApp.activate(ignoringOtherApps: true)
        if let pickerWindow {
            pickerWindow.makeKeyAndOrderFront(nil)
            return false
        }
        // Picker NSWindow was reclaimed (SwiftUI dismiss); ask any live scene
        // to re-open it via the standard SwiftUI action.
        NotificationCenter.default.post(name: .openPickerRequested, object: nil)
        return false
    }

    // MARK: - Window registration

    func registerMainWindow(_ window: NSWindow) {
        mainWindow = window
    }

    func registerPickerWindow(_ window: NSWindow) {
        pickerWindow = window
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
        presentMainWindow()
    }

    /// Bring the main editor window to the front via direct AppKit calls.
    ///
    /// We deliberately bypass `openWindow(id: "main")` here.  When the user
    /// has previously closed the main window via the red button,
    /// `CloseGuard` calls `orderOut(nil)` on the NSWindow — the SwiftUI
    /// scene remains structurally alive (so its state and the embedded
    /// WebView survive) but its view tree enters a "ghost" state where
    /// `.onReceive` subscribers and `openWindow(id:)` re-presentation are
    /// unreliable.  AppKit's `makeKeyAndOrderFront` doesn't care about any
    /// of that — it just shows the window, synchronously.
    private func presentMainWindow() {
        NSApp.activate(ignoringOtherApps: true)

        // Stash the picker if it's currently on screen, so it doesn't sit
        // in front of (or alongside) the main editor.  `orderOut` keeps
        // the NSWindow alive for later `applicationShouldHandleReopen`
        // calls to revive it.
        if let pickerWindow, pickerWindow.isVisible {
            pickerWindow.orderOut(nil)
        }

        if let mainWindow {
            mainWindow.makeKeyAndOrderFront(nil)
            return
        }

        // Cold-launch fallback: the main scene's NSWindow hasn't been
        // instantiated yet.  Whichever SwiftUI scene appears first (almost
        // always the picker, which is `.defaultLaunchBehavior(.presented)`)
        // will receive this notification and construct main via
        // `openWindow(id: "main")`.
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
