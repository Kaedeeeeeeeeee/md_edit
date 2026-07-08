import AppKit
import Observation

/// Registry of external-file document windows (B2 phase 2).
///
/// One entry per open document window, keyed by standardized file URL.
/// The manager owns each window's `DocumentSession`, the `NSWindow`
/// itself, and — when the file was opened through a security-scoped
/// bookmark (Recents) — the started scope handle, which must stay open
/// for the window's lifetime so autosave can keep writing, and be
/// released exactly once on close.
///
/// Why AppKit windows and not a SwiftUI `WindowGroup`: SwiftUI's
/// `openWindow` can't open a document window during **cold launch** — the
/// scene isn't active yet when the file-open Apple event arrives, so the
/// call silently no-ops (even delayed by half a second).  Worse, a
/// `WindowGroup(for: URL.self)` gets matched by SwiftUI's own file-open
/// routing, which closes the presented main window on the way.  This is
/// exactly the situation CLAUDE.md decision #6 describes: when SwiftUI's
/// windowing is unreliable, drive `NSWindow` directly.  The window's SwiftUI
/// content is hosted in an `NSHostingController` via the injected
/// `makeWindow` factory.
@MainActor
@Observable
final class DocumentWindowManager {
    final class Entry {
        let session: DocumentSession
        /// Strong: the manager is the sole owner keeping the window alive
        /// (windows are `isReleasedWhenClosed = false`).  Dropping the
        /// entry on close releases it.
        let window: NSWindow
        /// Started security-scoped URL backing this window's file access,
        /// if one was needed (bookmark-resolved opens).  LaunchServices
        /// opens (Finder double-click) carry an implicit process-lifetime
        /// grant and store nil here.
        let scopeURL: URL?

        init(session: DocumentSession, window: NSWindow, scopeURL: URL?) {
            self.session = session
            self.window = window
            self.scopeURL = scopeURL
        }
    }

    private(set) var entries: [URL: Entry] = [:]

    /// Builds the `NSWindow` (SwiftUI content + environment) for a prepared
    /// session.  Injected by `NotationApp` at startup because window
    /// construction needs the app-level environment objects that live on the
    /// App struct.
    var makeWindow: ((URL, DocumentSession) -> NSWindow)?

    /// Open a document window for `url`, or focus the existing one.
    /// Takes ownership of `heldScope` (a STARTED security-scoped URL):
    /// released when the window closes, or immediately if the window is
    /// already open.
    ///
    /// Re-opening an already-open URL focuses its window without reloading
    /// the session, preserving any unsaved editor state.
    func open(_ url: URL, heldScope: URL?) {
        let std = url.standardizedFileURL
        if let existing = entries[std] {
            heldScope?.stopAccessingSecurityScopedResource()
            NSApp.activate(ignoringOtherApps: true)
            existing.window.makeKeyAndOrderFront(nil)
            return
        }

        guard let makeWindow else {
            DebugLog.write("[docwin] makeWindow factory not wired — dropping open for \(std.lastPathComponent)")
            heldScope?.stopAccessingSecurityScopedResource()
            return
        }

        let session = DocumentSession()
        // External documents have no workspace: untitled autosave can't
        // happen here (the session always has a file), and tree refresh
        // is meaningless outside the sidebar.
        session.workspaceRoot = { nil }
        session.onFileWritten = { _ in }
        session.loadFile(std)

        let window = makeWindow(std, session)
        entries[std] = Entry(session: session, window: window, scopeURL: heldScope)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        DebugLog.write("[docwin] opened window for \(std.lastPathComponent) scope=\(heldScope != nil)")
    }

    func session(for url: URL) -> DocumentSession? {
        entries[url.standardizedFileURL]?.session
    }

    /// Tear down the entry for a closed window: cancel any pending
    /// autosave (the window is gone; a late fire would write into a file
    /// the user believes closed) and release the scope handle.  Dropping
    /// the entry releases the window.
    func close(_ url: URL) {
        let std = url.standardizedFileURL
        guard let entry = entries.removeValue(forKey: std) else { return }
        entry.session.cancelPendingAutoSave()
        entry.scopeURL?.stopAccessingSecurityScopedResource()
        DebugLog.write("[docwin] closed \(std.lastPathComponent)")
    }
}
