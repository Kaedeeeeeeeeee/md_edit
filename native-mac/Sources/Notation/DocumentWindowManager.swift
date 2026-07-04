import Foundation
import Observation

/// Registry of external-file document windows (B2 phase 2).
///
/// One entry per open document window, keyed by standardized file URL.
/// The manager owns each window's `DocumentSession` and — when the file
/// was opened through a security-scoped bookmark (Recents) — the started
/// scope handle, which must stay open for the window's lifetime so
/// autosave can keep writing, and be released exactly once on close.
///
/// The manager never opens NSWindows itself: `AppModel.openDocument`
/// prepares an entry here, then posts `.openDocumentWindowRequested`;
/// a modifier on the main scene calls SwiftUI's `openWindow(id:value:)`,
/// and `DocumentWindowView` looks its session up by URL.  Value-based
/// `WindowGroup` gives dedup for free: opening the same URL twice makes
/// the existing window key instead of spawning a sibling.
@MainActor
@Observable
final class DocumentWindowManager {
    struct Entry {
        let session: DocumentSession
        /// Started security-scoped URL backing this window's file access,
        /// if one was needed (bookmark-resolved opens).  LaunchServices
        /// opens (Finder double-click) carry an implicit process-lifetime
        /// grant and store nil here.
        let scopeURL: URL?
    }

    private(set) var entries: [URL: Entry] = [:]

    /// Prepare (or reuse) the session for `url` and return the
    /// standardized URL to hand to `openWindow(value:)`.  Takes ownership
    /// of `heldScope`: it will be released when the window closes.
    ///
    /// Re-opening an already-open URL intentionally does NOT reload the
    /// session — the existing window just gets focused, preserving any
    /// unsaved editor state.  A redundant `heldScope` for an existing
    /// entry is released immediately (the entry already holds one).
    @discardableResult
    func open(_ url: URL, heldScope: URL?) -> URL {
        let std = url.standardizedFileURL
        if entries[std] != nil {
            heldScope?.stopAccessingSecurityScopedResource()
            return std
        }

        let session = DocumentSession()
        // External documents have no workspace: untitled autosave can't
        // happen here (the session always has a file), and tree refresh
        // is meaningless outside the sidebar.
        session.workspaceRoot = { nil }
        session.onFileWritten = { _ in }
        session.loadFile(std)

        entries[std] = Entry(session: session, scopeURL: heldScope)
        DebugLog.write("[docwin] opened session for \(std.lastPathComponent) scope=\(heldScope != nil)")
        return std
    }

    func session(for url: URL) -> DocumentSession? {
        entries[url.standardizedFileURL]?.session
    }

    /// Tear down the entry for a closed window: cancel any pending
    /// autosave (the window is gone; a late fire would write into a file
    /// the user believes closed) and release the scope handle.
    func close(_ url: URL) {
        let std = url.standardizedFileURL
        guard let entry = entries.removeValue(forKey: std) else { return }
        entry.session.cancelPendingAutoSave()
        entry.scopeURL?.stopAccessingSecurityScopedResource()
        DebugLog.write("[docwin] closed \(std.lastPathComponent)")
    }
}
