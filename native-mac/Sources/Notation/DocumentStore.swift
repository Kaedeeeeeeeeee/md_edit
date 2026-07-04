import Foundation
import Observation
import AppKit
import UniformTypeIdentifiers

struct FileNode: Identifiable, Hashable {
    var id: String { url.path }
    let url: URL
    let name: String
    let isDirectory: Bool
    let children: [FileNode]
}

@MainActor
@Observable
final class DocumentStore {
    var folderURL: URL?
    var fileTree: [FileNode] = []

    /// The document open in the main window's editor.  Content, dirty
    /// tracking, autosave, encoding and the image-auth banner all live
    /// there — see `DocumentSession`.  The store injects its workspace
    /// hooks in `init` and coordinates cross-cutting flows (file ops that
    /// touch the open document, click-to-open).
    let document = DocumentSession()

    // MARK: - Sidebar UI state
    //
    // `currentFileURL` is the document open in the editor; `sidebar`
    // holds the orthogonal tree-UI state — multi-selection, cut/copy
    // clipboard, disclosed folders.  See `SidebarState` for semantics.
    // File operations below keep it consistent via translate/remove.
    let sidebar = SidebarState()

    private let folderWatcher = FolderWatcher()
    private var folderWatcherWired = false

    /// The workspace folder we currently hold a started security-scoped
    /// resource handle on.  Tracked separately from `folderURL` so we can
    /// `stopAccessingSecurityScopedResource()` on the previous URL before
    /// adopting a new one.  Without this, every workspace switch leaks the
    /// previous workspace's kernel handle for the lifetime of the process.
    private var workspaceAccessURL: URL?

    /// Ignore `FolderWatcher` callbacks until this date.  Bumped to
    /// `now + 0.4s` after any internal mutation (move/copy/rename/delete)
    /// so we don't rebuild twice (once explicitly, once via the watcher
    /// firing 250ms later).  Prevents visual flicker mid-operation.
    @ObservationIgnored private var suppressWatcherUntil: Date?

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
        document.workspaceRoot = { [weak self] in self?.folderURL }
        document.onFileWritten = { [weak self] _ in
            guard let self, self.folderURL != nil else { return }
            self.rebuildFileTree()
        }

        // Restore the previously-adopted workspace synchronously during init
        // so ContentView's first render sees the final `folderURL` value.
        // Without this, the onboarding gate flashes for a frame on every
        // launch even for returning users.
        restoreSavedWorkspaceIfAvailable()
    }

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
            adoptFolder(url)
            WorkspaceBookmark.save(url)
        }
    }

    /// Set the active workspace folder and refresh the file tree.
    /// Caller is responsible for having started access on `url` if it came
    /// from a security-scoped bookmark.
    func adoptFolder(_ url: URL) {
        // Release the previous workspace's security-scoped handle before
        // adopting a new one.  WorkspaceBookmark.restore / adoptRecent /
        // and the NSOpenPanel path all leave the URL with a started handle
        // that has to be paired with a stop somewhere.  Without this,
        // every workspace switch leaks one kernel handle for the
        // lifetime of the process.
        if let previous = workspaceAccessURL, previous != url {
            previous.stopAccessingSecurityScopedResource()
        }
        workspaceAccessURL = url

        folderURL = url
        rebuildFileTree()
        if !folderWatcherWired {
            folderWatcher.onChange = { [weak self] in
                self?.handleExternalFolderChange()
            }
            folderWatcherWired = true
        }
        folderWatcher.start(watching: url)
    }

    /// Called by FolderWatcher when something on disk changed inside the
    /// active workspace. Refreshes the tree; doesn't touch the open document.
    /// Suppressed for a short window after internal mutations so we don't
    /// rebuild twice for the same change.
    func handleExternalFolderChange() {
        if let suppress = suppressWatcherUntil, Date() < suppress { return }
        rebuildFileTree()
    }

    /// Quiet the FolderWatcher for ~0.4s while an internal batch finishes.
    /// Caller is responsible for invoking `rebuildFileTree()` themselves
    /// once the batch is complete.
    private func beginInternalMutation() {
        suppressWatcherUntil = Date().addingTimeInterval(0.4)
    }

    /// Try to re-adopt the workspace folder that was open at the previous
    /// quit. Called once from the App scene at launch.
    func restoreSavedWorkspaceIfAvailable() {
        guard folderURL == nil else { return }
        if let url = WorkspaceBookmark.restore() {
            adoptFolder(url)
        }
    }

    /// Switch to one of the recently-used workspace folders.
    func adoptRecentWorkspace(_ url: URL) {
        if let resolved = WorkspaceBookmark.adoptRecent(url) {
            adoptFolder(resolved)
        }
    }

    // MARK: - File tree mutations

    /// Create a new empty .md file inside `parent` (use folderURL if nil).
    /// Returns the created URL on success.
    @discardableResult
    func createNewFile(in parent: URL? = nil) -> URL? {
        let dir = parent ?? folderURL
        guard let dir else { return nil }
        guard let name = AppAlerts.promptForName(
            title: String(localized: "New File"),
            placeholder: "Untitled.md",
            defaultValue: "Untitled.md"
        ), !name.isEmpty else { return nil }
        let finalName = name.hasSuffix(".md") ? name : "\(name).md"
        let url = FilePaths.uniqueURL(in: dir, name: finalName)
        do {
            try "".write(to: url, atomically: true, encoding: .utf8)
            rebuildFileTree()
            document.loadFile(url)
            return url
        } catch {
            AppAlerts.present(String(localized: "Failed to create file"), error.localizedDescription)
            return nil
        }
    }

    @discardableResult
    func createNewFolder(in parent: URL? = nil) -> URL? {
        let dir = parent ?? folderURL
        guard let dir else { return nil }
        guard let name = AppAlerts.promptForName(
            title: String(localized: "New Folder"),
            placeholder: "Untitled Folder",
            defaultValue: "Untitled Folder"
        ), !name.isEmpty else { return nil }
        let url = FilePaths.uniqueURL(in: dir, name: name)
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            rebuildFileTree()
            return url
        } catch {
            AppAlerts.present(String(localized: "Failed to create folder"), error.localizedDescription)
            return nil
        }
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

    /// Rename `url` to `newName` (last-path-component only — full paths
    /// are rejected).  Returns the new URL on success or nil on failure /
    /// no-op.  Handles:
    ///   - empty / whitespace-only names (rejects)
    ///   - illegal `/` or `:` characters (rejects)
    ///   - same-name short-circuit (no-op success)
    ///   - collisions (resolved via `uniqueURL`)
    ///   - selection / currentFileURL / clipboard URL translation
    ///   - watcher suppression so the disk-side rename doesn't double-fire
    @discardableResult
    func rename(_ url: URL, to newName: String) -> URL? {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard !trimmed.contains("/"), !trimmed.contains(":") else {
            AppAlerts.present(
                String(localized: "Invalid name"),
                String(localized: "Names cannot contain “/” or “:”.")
            )
            return nil
        }
        if trimmed == url.lastPathComponent { return url }

        // Decide the final filename, taking collisions into account.
        let parent = url.deletingLastPathComponent()
        let collisionFree = FilePaths.uniqueURL(in: parent, name: trimmed)
        let dest = collisionFree

        beginInternalMutation()
        do {
            try FileManager.default.moveItem(at: url, to: dest)
            translateURL(from: url, to: dest)
            rebuildFileTree()
            DebugLog.write("[fileop] rename \(url.lastPathComponent) -> \(dest.lastPathComponent)")
            return dest
        } catch {
            AppAlerts.present(String(localized: "Failed to rename"), error.localizedDescription)
            return nil
        }
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
    /// Updates selection / currentFileURL / clipboard if any deleted URL
    /// matched.  If the user dismisses the alert, no items are touched.
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

        beginInternalMutation()
        var trashedOpenDoc = false
        for url in standardised {
            do {
                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                if document.currentFileURL?.standardizedFileURL == url {
                    trashedOpenDoc = true
                }
                sidebar.remove(url)
                DebugLog.write("[fileop] trashed \(url.lastPathComponent)")
            } catch {
                DebugLog.write("[fileop] trash FAILED \(url.lastPathComponent): \(error.localizedDescription)")
                AppAlerts.present(String(localized: "Failed to move to Trash"), error.localizedDescription)
            }
        }
        if trashedOpenDoc {
            document.reset()
        }
        rebuildFileTree()
    }

    /// Delete every URL currently in the sidebar selection.  Used by the
    /// Delete key and the Edit menu's "Delete Selection" command.
    func deleteSelection() {
        delete(Array(sidebar.selection))
    }

    // MARK: - Move / Copy / Paste

    /// Move N URLs into `destination` (a folder).  Same-volume → rename
    /// (via `FileManager.moveItem`).  Cross-volume → copy + remove
    /// (matches Finder semantics).  Refuses to move a folder into itself
    /// or its descendant.  Collisions resolved via `uniqueURL`.
    @discardableResult
    func move(_ urls: [URL], into destination: URL) -> [URL] {
        guard !urls.isEmpty else { return [] }
        let destStd = destination.standardizedFileURL

        // Reject "drop into self / descendant" up front for any source.
        for src in urls {
            let srcStd = src.standardizedFileURL
            if FilePaths.contains(parent: srcStd, child: destStd) {
                NSSound.beep()
                DebugLog.write("[fileop] move refused (cycle): \(srcStd.lastPathComponent) → \(destStd.path)")
                return []
            }
        }

        beginInternalMutation()
        var newURLs: [URL] = []
        for src in urls {
            let dest = FilePaths.uniqueURL(in: destination, name: src.lastPathComponent)
            do {
                try FileManager.default.moveItem(at: src, to: dest)
                translateURL(from: src, to: dest)
                newURLs.append(dest)
                DebugLog.write("[fileop] move \(src.lastPathComponent) → \(dest.path)")
            } catch {
                DebugLog.write("[fileop] move FAILED \(src.lastPathComponent): \(error.localizedDescription)")
                AppAlerts.present(String(localized: "Failed to move"), error.localizedDescription)
            }
        }
        rebuildFileTree()
        return newURLs
    }

    /// Recursively copy N URLs into `destination`.  Collisions resolved
    /// via `uniqueURL`.  Doesn't mutate currentFileURL / selection
    /// because the originals are still there.
    @discardableResult
    func copy(_ urls: [URL], into destination: URL) -> [URL] {
        guard !urls.isEmpty else { return [] }
        beginInternalMutation()
        var newURLs: [URL] = []
        for src in urls {
            let dest = FilePaths.uniqueURL(in: destination, name: src.lastPathComponent)
            do {
                try FileManager.default.copyItem(at: src, to: dest)
                newURLs.append(dest)
                DebugLog.write("[fileop] copy \(src.lastPathComponent) → \(dest.path)")
            } catch {
                DebugLog.write("[fileop] copy FAILED \(src.lastPathComponent): \(error.localizedDescription)")
                AppAlerts.present(String(localized: "Failed to copy"), error.localizedDescription)
            }
        }
        rebuildFileTree()
        return newURLs
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
        return folderURL
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
    /// range selection.  Lives here because it needs `fileTree`.
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
        walk(fileTree)
        return result
    }

    // (Path containment helper `FilePaths.contains(parent:, child:)` is defined
    // further down in the "Filesystem helpers" section — reuse that one.)

    func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: - Attachments

    /// Write `data` to `<scopeRoot>/attachments/<uuid>.<ext>` and return
    /// the path relative to `scopeRoot` (e.g. `"attachments/abc.png"`).
    /// `scopeRoot` is whichever directory the caller has security-scoped
    /// access to — for in-vault documents that's the workspace, for
    /// floating documents it's the parent dir the user authorised via
    /// `DocumentDirBookmarks.requestGrant`.
    func saveImageToAttachments(data: Data, ext: String, in scopeRoot: URL) throws -> String {
        let attachments = scopeRoot.appendingPathComponent("attachments", isDirectory: true)
        try FileManager.default.createDirectory(at: attachments, withIntermediateDirectories: true)
        let safeExt = sanitizedExtension(ext)
        let filename = "\(UUID().uuidString.lowercased()).\(safeExt)"
        let target = attachments.appendingPathComponent(filename)
        try data.write(to: target)
        // Only refresh the sidebar tree when the new attachment lives in the
        // active workspace.  Attachments inside a per-doc grant directory
        // aren't shown in the sidebar (sidebar = workspace).
        if let folder = folderURL,
           scopeRoot.standardizedFileURL.path == folder.standardizedFileURL.path {
            rebuildFileTree()
        }
        DebugLog.write("[paste] wrote \(filename) under \(scopeRoot.lastPathComponent)")
        return "attachments/\(filename)"
    }

    private func sanitizedExtension(_ ext: String) -> String {
        let trimmed = ext.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed = trimmed.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) }
        if !trimmed.isEmpty, allowed, trimmed.count <= 6 { return trimmed }
        return "png"
    }

    // MARK: - File tree

    func rebuildFileTree() {
        guard let folderURL else {
            fileTree = []
            return
        }
        fileTree = scanFolder(folderURL)
    }

    private func scanFolder(_ url: URL) -> [FileNode] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        var nodes: [FileNode] = []
        for entry in entries {
            let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDir {
                // Hide our own automatic `attachments/` directory — it
                // holds pasted-image bytes, not user-managed notes, and
                // would clutter the sidebar.  Everything else shows
                // regardless of whether it's empty so newly-created
                // folders are visible immediately.
                if entry.lastPathComponent == "attachments" { continue }
                let children = scanFolder(entry)
                nodes.append(FileNode(
                    url: entry,
                    name: entry.lastPathComponent,
                    isDirectory: true,
                    children: children
                ))
            } else if FilePaths.isMarkdown(entry) {
                nodes.append(FileNode(
                    url: entry,
                    name: entry.lastPathComponent,
                    isDirectory: false,
                    children: []
                ))
            }
        }
        nodes.sort { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory {
                return lhs.isDirectory
            }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
        return nodes
    }

}
