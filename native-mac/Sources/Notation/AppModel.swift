import Foundation
import Observation
import AppKit

/// Coordinator for the main window.  Owns the three state layers —
///
///   `workspace`  folder, file tree, watcher, filesystem mutations
///   `document`   the open document's content / dirty / autosave
///   `sidebar`    tree-UI state: selection, clipboard, disclosure
///
/// — plus the app-level workspace registry (security-scoped bookmarks,
/// recents via `WorkspaceBookmark`), and implements the flows that cross
/// layer boundaries: click-selects-and-opens, file ops that must update
/// selection and the open document, paste-destination resolution.
///
/// B2 refactor, phase 1: this used to be a 1000-line god object holding
/// all three layers' state inline.  Phase 2 turns the document layer
/// into a per-window session; the workspace/sidebar pair stays bound to
/// the main window.
@MainActor
@Observable
final class AppModel {
    let workspace = WorkspaceSession()
    let document = DocumentSession()
    let sidebar = SidebarState()

    /// External-file document windows (B2 phase 2): sessions + security
    /// scopes for every open document window, keyed by file URL.
    let documentWindows = DocumentWindowManager()

    init() {
        // Register UserDefaults defaults BEFORE anything reads autosave keys.
        // `@AppStorage` initializers only apply once the matching SettingsView
        // is constructed — until then, plain `.bool(forKey:)` calls return
        // false for missing keys, which silently disables autosave on first
        // launch.  This registration makes "key missing" mean the value
        // below without writing to disk.
        UserDefaults.standard.register(defaults: [
            "autoSaveEnabled": true,
            "autoSaveDelaySeconds": 2.0
        ])

        // First-launch-after-install: ask macOS to make Notation the
        // default handler for .md files.  Idempotent — the helper tracks a
        // flag in UserDefaults so we only do it once.
        DefaultMarkdownHandler.claimAsDefaultIfNeeded()

        // Wire the document session's workspace hooks.  Weak self: the
        // session is owned by this store, so a strong capture would cycle.
        document.workspaceRoot = { [weak self] in self?.workspace.folderURL }
        document.onFileWritten = { [weak self] _ in
            guard let self, self.workspace.folderURL != nil else { return }
            self.workspace.rebuildFileTree()
        }

        // Restore the previously-adopted workspace synchronously during init
        // so ContentView's first render sees the final `folderURL` value.
        // Without this, the onboarding gate flashes for a frame on every
        // launch even for returning users.
        restoreSavedWorkspaceIfAvailable()
    }

    // MARK: - Document opening / routing

    /// Posted after `documentWindows` enqueues a window value; the main
    /// scene's `DocumentWindowOpener` reacts by draining the queue into
    /// `openWindow(id:"document", value:)`.  Notification + queue rather
    /// than a plain notification payload so cold-launch opens that fire
    /// before any view exists still land (the opener also drains on
    /// appear).  Same environment-action-unreachable-from-AppKit problem
    /// `.openMainRequested` solves for the main window.
    static let openDocumentWindowRequested = Notification.Name("com.notation.openDocumentWindowRequested")

    /// Single entry point for "open this markdown file", whatever the
    /// source (Finder double-click, Open File…, Recents menu).  The
    /// routing rule that retires the old hybrid state: files inside the
    /// workspace load in the main window with the sidebar revealing the
    /// row; anything else gets its own document window.
    ///
    /// `heldScope` is a STARTED security-scoped URL backing access to
    /// `url` (bookmark-resolved opens).  Ownership transfers here:
    /// released immediately for workspace files — the workspace grant
    /// already covers them — and handed to the window registry
    /// otherwise, to be released when that window closes.
    func openDocument(at url: URL, heldScope: URL? = nil) {
        let std = url.standardizedFileURL
        if let folder = workspace.folderURL, FilePaths.contains(parent: folder, child: std) {
            document.loadFile(std)
            sidebar.selectOnly(std)
            revealInSidebar(std)
            heldScope?.stopAccessingSecurityScopedResource()
            AppDelegate.shared?.showMainWindow()
        } else {
            documentWindows.open(std, heldScope: heldScope)
            // Async post: when several file-open Apple events arrive in
            // quick succession (Finder "Open" on a multi-selection), a
            // synchronous notification fired from inside the AE handler
            // races SwiftUI's scene update — `openWindow` no-ops and the
            // value stays stranded in the queue.  Deferring to a fresh
            // main-runloop tick lets each open settle before the drain.
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: Self.openDocumentWindowRequested, object: nil)
            }
        }
    }

    /// Open File… panel.  Lives here (not on DocumentSession) because the
    /// picked file must be routed like any other open — the old
    /// per-session dialog always loaded into its own editor, which is
    /// exactly the hybrid state phase 2 removes.  No discard prompt:
    /// workspace files replace the main document under the same
    /// autosave-covers-it semantics as a sidebar click, and external
    /// files don't touch the main document at all.
    func openFileDialog() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = FilePaths.markdownContentTypes()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            openDocument(at: url)
        }
    }

    /// Expand the folder chain leading to `url` so the just-selected row
    /// is actually visible.  Walks the scanned tree and inserts the tree's
    /// own node URLs — deriving ancestor URLs by path math would produce
    /// URLs that fail `Set` equality against the scanner's (trailing-slash
    /// representation differences).
    private func revealInSidebar(_ url: URL) {
        let targetPath = url.standardizedFileURL.path
        func walk(_ nodes: [FileNode]) {
            for node in nodes where node.isDirectory {
                let dirPath = node.url.standardizedFileURL.path
                let needle = dirPath.hasSuffix("/") ? dirPath : dirPath + "/"
                if targetPath.hasPrefix(needle) {
                    sidebar.expanded.insert(node.url)
                    walk(node.children)
                    return
                }
            }
        }
        walk(workspace.fileTree)
    }

    // MARK: - Workspace adoption / registry

    func openFolderDialog() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        // Surface the "New Folder" button at the bottom-left of the panel so
        // users can spin up a fresh workspace folder without bouncing out to
        // Finder.  Sandbox grants the resulting URL the same as any other
        // user-selected path.
        panel.canCreateDirectories = true
        panel.prompt = "Use This Folder"
        panel.message = "Choose a folder for your workspace, or click “New Folder” to create one."
        if panel.runModal() == .OK, let url = panel.url {
            adoptWorkspaceFolder(url)
        }
    }

    /// Adopt `url` as the active workspace AND persist it to the
    /// bookmark registry (current + recents).  Used by the folder picker
    /// and onboarding; restore paths call `workspace.adopt` directly
    /// because their bookmark is already saved.
    func adoptWorkspaceFolder(_ url: URL) {
        workspace.adopt(url)
        WorkspaceBookmark.save(url)
    }

    /// Try to re-adopt the workspace folder that was open at the previous
    /// quit. Called once from init at launch.
    func restoreSavedWorkspaceIfAvailable() {
        guard workspace.folderURL == nil else { return }
        if let url = WorkspaceBookmark.restore() {
            workspace.adopt(url)
        }
    }

    /// Switch to one of the recently-used workspace folders.
    func adoptRecentWorkspace(_ url: URL) {
        if let resolved = WorkspaceBookmark.adoptRecent(url) {
            workspace.adopt(resolved)
        }
    }

    // MARK: - Coordinated file operations
    //
    // The pattern throughout: `workspace` performs the filesystem work
    // and reports what happened; this layer applies the consequences to
    // `document` (open file moved/trashed) and `sidebar` (URL-keyed
    // selection/clipboard state).

    /// Create a new empty .md file and open it in the editor.
    @discardableResult
    func createNewFile(in parent: URL? = nil) -> URL? {
        guard let url = workspace.createNewFile(in: parent) else { return nil }
        document.loadFile(url)
        return url
    }

    @discardableResult
    func createNewFolder(in parent: URL? = nil) -> URL? {
        workspace.createNewFolder(in: parent)
    }

    /// Legacy NSAlert-based rename — kept so the context-menu "Rename…"
    /// item continues to work without inline editing focus.  Forwards to
    /// the headless `rename(_:to:)`.
    func rename(_ url: URL) {
        guard let newName = AppAlerts.promptForName(
            title: String(localized: "Rename"),
            placeholder: url.lastPathComponent,
            defaultValue: url.lastPathComponent
        ) else { return }
        _ = rename(url, to: newName)
    }

    /// Rename on disk, then translate the open document / selection /
    /// clipboard if they referenced the old URL.
    @discardableResult
    func rename(_ url: URL, to newName: String) -> URL? {
        guard let dest = workspace.rename(url, to: newName) else { return nil }
        if dest.standardizedFileURL != url.standardizedFileURL {
            translateURL(from: url, to: dest)
        }
        return dest
    }

    /// Update every URL-keyed piece of state when a path on disk moves
    /// from `old` to `new`.  Called by rename/move/paste.
    private func translateURL(from old: URL, to new: URL) {
        document.noteFileMoved(from: old, to: new)
        sidebar.translate(from: old, to: new)
    }

    /// Single-URL delete — kept as a convenience.  Forwards to `delete(_:[URL])`.
    func delete(_ url: URL) {
        delete([url])
    }

    /// Move N items to the system Trash with one confirmation alert.
    /// Updates selection / the open document if any deleted URL matched.
    /// If the user dismisses the alert, no items are touched.
    func delete(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let standardised = urls.map { $0.standardizedFileURL }

        let alert = NSAlert()
        if standardised.count == 1 {
            alert.messageText = String(
                localized: "Move “\(standardised[0].lastPathComponent)” to the Trash?"
            )
        } else {
            alert.messageText = String(
                localized: "Move \(standardised.count) items to the Trash?"
            )
        }
        alert.informativeText = String(localized: "You can restore them from the Trash if needed.")
        alert.alertStyle = .warning
        alert.addButton(withTitle: String(localized: "Move to Trash"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        var trashedOpenDoc = false
        for url in workspace.trash(standardised) {
            if document.currentFileURL?.standardizedFileURL == url {
                trashedOpenDoc = true
            }
            sidebar.remove(url)
        }
        if trashedOpenDoc {
            document.reset()
        }
    }

    /// Delete every URL currently in the sidebar selection.  Used by the
    /// Delete key and the Edit menu's "Delete Selection" command.
    func deleteSelection() {
        delete(Array(sidebar.selection))
    }

    /// Move into `destination`, then translate URL-keyed state for every
    /// item that actually moved.  Returns the new URLs.
    @discardableResult
    func move(_ urls: [URL], into destination: URL) -> [URL] {
        let moved = workspace.move(urls, into: destination)
        for (from, to) in moved {
            translateURL(from: from, to: to)
        }
        return moved.map(\.to)
    }

    @discardableResult
    func copy(_ urls: [URL], into destination: URL) -> [URL] {
        workspace.copy(urls, into: destination)
    }

    /// Consume the sidebar clipboard into the destination directory.
    /// `into == nil` → resolve to a sensible default: single-selected
    /// folder → that folder; selected file → its parent; otherwise →
    /// workspace root.  Lives here (not on SidebarState) because it
    /// performs the actual file operations.
    func paste(into requestedDest: URL?) {
        guard let clip = sidebar.clipboard else { return }
        let dest = requestedDest ?? defaultPasteDestination()
        guard let dest else { return }
        switch clip.op {
        case .cut:
            let newURLs = move(clip.urls, into: dest)
            if !newURLs.isEmpty {
                sidebar.clipboard = nil
                sidebar.selection = Set(newURLs.map { $0.standardizedFileURL })
            }
        case .copy:
            let newURLs = copy(clip.urls, into: dest)
            if !newURLs.isEmpty {
                sidebar.selection = Set(newURLs.map { $0.standardizedFileURL })
            }
        }
    }

    /// Workspace root if no selection, else the parent of the first
    /// selected item (or the item itself if it's a folder).
    private func defaultPasteDestination() -> URL? {
        if sidebar.selection.count == 1, let only = sidebar.selection.first {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: only.path, isDirectory: &isDir), isDir.boolValue {
                return only
            }
            return only.deletingLastPathComponent()
        }
        return workspace.folderURL
    }

    // MARK: - Selection coordination

    /// Plain click on a row: select only this URL, and load the file
    /// into the editor when it's a file (folders just toggle their own
    /// expansion state in the caller).  Pure selection mechanics live on
    /// `sidebar`; this wrapper adds the "clicking a file opens it"
    /// coordination, which is exactly the part that needs the document
    /// side of the store.
    func selectOnly(_ url: URL, loadIfFile: Bool = true) {
        sidebar.selectOnly(url)
        if loadIfFile {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
               !isDir.boolValue,
               document.currentFileURL?.standardizedFileURL != url.standardizedFileURL {
                document.loadFile(url)
            }
        }
    }

    /// Compute the flat top-to-bottom visible URL order from the file
    /// tree and the sidebar's disclosed folders.  Used by Shift+click
    /// range selection.  Lives here because it needs both layers.
    func flattenedVisibleURLs() -> [URL] {
        var result: [URL] = []
        func walk(_ nodes: [FileNode]) {
            for node in nodes {
                result.append(node.url)
                if node.isDirectory, sidebar.expanded.contains(node.url) {
                    walk(node.children)
                }
            }
        }
        walk(workspace.fileTree)
        return result
    }

    func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
