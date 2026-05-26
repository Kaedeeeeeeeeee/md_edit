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

/// Pasteboard-like state held on `DocumentStore` so menu-bar commands and
/// the sidebar context menu can coordinate Cut/Copy/Paste across the
/// whole window.  When `op == .cut`, the rows render at half opacity so
/// the user remembers they have a pending move.
struct SidebarClipboard: Equatable {
    enum Op { case cut, copy }
    var urls: [URL]
    var op: Op
}

@MainActor
@Observable
final class DocumentStore {
    var folderURL: URL?
    var currentFileURL: URL?
    var currentMarkdown: String = ""
    var isDirty: Bool = false
    var fileTree: [FileNode] = []

    /// Monotonically increments every time we want the editor to re-pull
    /// content from the store (file open, new document, current file deleted).
    /// Editor-originated edits do NOT bump this — that would loop back.
    /// EditorWebView observes this and pushes `currentMarkdown` into JS when
    /// it changes.
    var loadEpoch: Int = 0

    /// True when the open document references a local image but lives in a
    /// folder Notation hasn't been granted read access to — i.e. a single
    /// file opened from outside the workspace, before any folder
    /// authorisation.  Drives the non-blocking "Allow Access" banner in
    /// ContentView.  Computed once per `loadFile` (never as a hot property —
    /// the readability probe touches security-scoped bookmarks).
    var localImageAuthNeeded: Bool = false

    // MARK: - Sidebar selection / clipboard
    //
    // `currentFileURL` is the document open in the editor.  `selection` is
    // an orthogonal multi-selection used by the sidebar UI for batch
    // operations (delete, drag-drop, cut/copy/paste).  They overlap when
    // the user clicks one file (selection = [that file]); they diverge
    // when the user ⌘-clicks to add files without changing the editor.
    // All URLs are stored standardised so `Set` membership is stable.

    /// Multi-selection.  Cleared by `loadFile`/`newDocument` so it never
    /// references stale URLs.  Mutated by NodeRow click handlers and
    /// menu-bar commands.
    var selection: Set<URL> = []

    /// Anchor for Shift+click range selection — the URL of the last row
    /// the user clicked without holding ⌘.  Nil after `clearSelection()`.
    var anchorURL: URL?

    /// Cut/Copy pasteboard, consumed by `paste(into:)`.  `op == .cut`
    /// items render at 50% opacity in the sidebar.
    var clipboard: SidebarClipboard?

    private var autoSaveTask: Task<Void, Never>?
    private let folderWatcher = FolderWatcher()
    private var folderWatcherWired = false

    /// Once auto-save has chosen a filename for an untitled document, reuse it
    /// for subsequent autosaves in the same session.  Cleared on
    /// `newDocument()` / `loadFile()`.  Without this, rapid edits after the
    /// timestamp tick boundary spawn multiple `Untitled-…` files.
    private var untitledAutosaveName: String?

    /// Encoding detected when we last `loadFile`d.  Preserved on save so
    /// opening a UTF-16 / GB18030 file and saving it doesn't silently
    /// transcode the user's bytes to UTF-8.
    private var currentFileEncoding: String.Encoding = .utf8

    /// The workspace folder we currently hold a started security-scoped
    /// resource handle on.  Tracked separately from `folderURL` so we can
    /// `stopAccessingSecurityScopedResource()` on the previous URL before
    /// adopting a new one.  Without this, every workspace switch leaks the
    /// previous workspace's kernel handle for the lifetime of the process.
    private var workspaceAccessURL: URL?

    /// Suppress `handleEditorChange` while we're pushing a freshly-loaded
    /// document into the editor.  BlockNote re-emits an onChange post-
    /// `replaceBlocks` with its own normalised markdown (trailing newlines,
    /// whitespace), which without this flag would mark the doc dirty the
    /// instant it loads and silently trigger autosave to a normalised form
    /// that rewrites the user's file or spawns a phantom Untitled.
    @ObservationIgnored private var isPriming: Bool = false
    @ObservationIgnored private var primingTask: Task<Void, Never>?

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

        // Restore the previously-adopted workspace synchronously during init
        // so ContentView's first render sees the final `folderURL` value.
        // Without this, the onboarding gate flashes for a frame on every
        // launch even for returning users.
        restoreSavedWorkspaceIfAvailable()
    }

    // Called by JS bridge whenever editor content changes.
    func handleEditorChange(_ markdown: String) {
        if isPriming {
            // Editor's first onChange after replaceBlocks is BlockNote's own
            // normalisation, not user input.  Track the markdown so dirty
            // detection has the right baseline, but don't flip dirty.
            currentMarkdown = markdown
            return
        }
        currentMarkdown = markdown
        isDirty = true
        scheduleAutoSave()
    }

    /// Cancel any pending auto-save task.  Required before:
    ///   - Discarding dirty changes (CloseGuard "Don't Save")
    ///   - Loading a different document
    ///   - Creating a new document
    /// Without this, a task scheduled before the user discarded their work
    /// fires after `currentFileURL` and `currentMarkdown` have been swapped,
    /// either zombie-writing discarded content or stomping on freshly-loaded
    /// content with stale data.
    func cancelPendingAutoSave() {
        autoSaveTask?.cancel()
        autoSaveTask = nil
    }

    /// Open a 1-second window during which `handleEditorChange` only updates
    /// the cached markdown and does not flip dirty / schedule autosave.
    /// Callers (newDocument, loadFile) invoke this immediately before
    /// triggering an editor re-render so BlockNote's normalisation echo
    /// doesn't masquerade as user input.
    private func beginPriming() {
        isPriming = true
        primingTask?.cancel()
        primingTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled, let self else { return }
            self.isPriming = false
        }
    }

    private func scheduleAutoSave() {
        autoSaveTask?.cancel()
        let defaults = UserDefaults.standard
        let enabled = defaults.bool(forKey: "autoSaveEnabled")
        guard enabled, !currentMarkdown.isEmpty else { return }
        let delay = defaults.double(forKey: "autoSaveDelaySeconds")
        let seconds = delay > 0 ? delay : 2.0
        autoSaveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            guard self.isDirty, !self.currentMarkdown.isEmpty else { return }
            if self.currentFileURL != nil {
                self.save()
            } else if self.folderURL != nil {
                self.autosaveAsUntitled()
            }
            // If both are nil (no vault, no file), nothing we can do safely.
            // After phase-2 onboarding `folderURL` always exists, so this
            // branch is effectively unreachable.
        }
    }

    /// Persist an untitled document into the active workspace using a
    /// timestamped filename, then promote it to `currentFileURL` so
    /// subsequent saves go through the standard path.
    private func autosaveAsUntitled() {
        guard let folder = folderURL else { return }
        if untitledAutosaveName == nil {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd-HH-mm-ss"
            untitledAutosaveName = "Untitled-\(formatter.string(from: Date())).md"
        }
        guard let name = untitledAutosaveName else { return }
        let target = uniqueURL(in: folder, name: name)
        do {
            try currentMarkdown.write(to: target, atomically: true, encoding: .utf8)
            currentFileURL = target
            isDirty = false
            RecentFiles.shared.push(target)
            rebuildFileTree()
            DebugLog.write("[autosave] created untitled \(target.lastPathComponent)")
        } catch {
            DebugLog.write("[autosave] untitled write failed: \(error.localizedDescription)")
        }
    }

    func newDocument() {
        guard confirmDiscardIfDirty() else { return }
        cancelPendingAutoSave()
        untitledAutosaveName = nil
        beginPriming()
        currentFileURL = nil
        currentMarkdown = ""
        localImageAuthNeeded = false
        isDirty = false
        loadEpoch += 1
    }

    func openFileDialog() {
        guard confirmDiscardIfDirty() else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = markdownTypes()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            loadFile(url)
        }
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

    func loadFile(_ url: URL) {
        do {
            // Size guard — refuse files >20 MB so a stray log file can't pin
            // the main thread on String(contentsOf:) or OOM the WKWebView
            // when we splice the doc into evaluateJavaScript.
            let resourceValues = try url.resourceValues(forKeys: [.fileSizeKey])
            if let size = resourceValues.fileSize, size > 20 * 1024 * 1024 {
                let sizeStr = ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
                presentAlert(
                    String(localized: "File too large"),
                    String(format: String(localized: "Notation can open Markdown files up to 20 MB. This file is %@."), sizeStr)
                )
                return
            }
            // Auto-detect encoding — handles UTF-8 BOM, UTF-16 BE/LE BOM,
            // system default fallback. Remember the encoding so
            // writeMarkdown(to:) doesn't silently transcode UTF-16 → UTF-8
            // on save.
            var detected: String.Encoding = .utf8
            let content = try String(contentsOf: url, usedEncoding: &detected)
            currentFileEncoding = detected
            cancelPendingAutoSave()
            untitledAutosaveName = nil
            beginPriming()
            currentFileURL = url
            currentMarkdown = content
            localImageAuthNeeded = computeLocalImageAuthNeeded(for: url, markdown: content)
            isDirty = false
            loadEpoch += 1
            RecentFiles.shared.push(url)
        } catch {
            DebugLog.write("[loadFile] FAILED \(error.localizedDescription)")
            presentAlert(String(localized: "Failed to open file"), error.localizedDescription)
        }
    }

    func save() {
        if let url = currentFileURL {
            writeMarkdown(to: url)
        } else {
            saveAs()
        }
    }

    func saveAs() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.init(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = currentFileURL?.lastPathComponent ?? "Untitled.md"
        if panel.runModal() == .OK, let url = panel.url {
            writeMarkdown(to: url)
            currentFileURL = url
            untitledAutosaveName = nil // committed to an explicit filename
        }
    }

    private func writeMarkdown(to url: URL) {
        do {
            try currentMarkdown.write(to: url, atomically: true, encoding: currentFileEncoding)
            isDirty = false
            RecentFiles.shared.push(url)
            if folderURL != nil { rebuildFileTree() }
        } catch {
            presentAlert(String(localized: "Failed to save"), error.localizedDescription)
        }
    }

    private func confirmDiscardIfDirty() -> Bool {
        guard isDirty else { return true }
        let alert = NSAlert()
        alert.messageText = String(localized: "You have unsaved changes.")
        alert.informativeText = String(localized: "Discard them and continue?")
        alert.alertStyle = .warning
        alert.addButton(withTitle: String(localized: "Discard"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func presentAlert(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }

    // MARK: - File tree mutations

    /// Create a new empty .md file inside `parent` (use folderURL if nil).
    /// Returns the created URL on success.
    @discardableResult
    func createNewFile(in parent: URL? = nil) -> URL? {
        let dir = parent ?? folderURL
        guard let dir else { return nil }
        guard let name = promptForName(
            title: String(localized: "New File"),
            placeholder: "Untitled.md",
            defaultValue: "Untitled.md"
        ), !name.isEmpty else { return nil }
        let finalName = name.hasSuffix(".md") ? name : "\(name).md"
        let url = uniqueURL(in: dir, name: finalName)
        do {
            try "".write(to: url, atomically: true, encoding: .utf8)
            rebuildFileTree()
            loadFile(url)
            return url
        } catch {
            presentAlert(String(localized: "Failed to create file"), error.localizedDescription)
            return nil
        }
    }

    @discardableResult
    func createNewFolder(in parent: URL? = nil) -> URL? {
        let dir = parent ?? folderURL
        guard let dir else { return nil }
        guard let name = promptForName(
            title: String(localized: "New Folder"),
            placeholder: "Untitled Folder",
            defaultValue: "Untitled Folder"
        ), !name.isEmpty else { return nil }
        let url = uniqueURL(in: dir, name: name)
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            rebuildFileTree()
            return url
        } catch {
            presentAlert(String(localized: "Failed to create folder"), error.localizedDescription)
            return nil
        }
    }

    /// Legacy NSAlert-based rename — kept so the context-menu "Rename…"
    /// item continues to work without inline editing focus.  Forwards to
    /// the headless `rename(_:to:)`.
    func rename(_ url: URL) {
        guard let newName = promptForName(
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
            presentAlert(
                String(localized: "Invalid name"),
                String(localized: "Names cannot contain “/” or “:”.")
            )
            return nil
        }
        if trimmed == url.lastPathComponent { return url }

        // Decide the final filename, taking collisions into account.
        let parent = url.deletingLastPathComponent()
        let collisionFree = uniqueURL(in: parent, name: trimmed)
        let dest = collisionFree

        beginInternalMutation()
        do {
            try FileManager.default.moveItem(at: url, to: dest)
            translateURL(from: url, to: dest)
            rebuildFileTree()
            DebugLog.write("[fileop] rename \(url.lastPathComponent) -> \(dest.lastPathComponent)")
            return dest
        } catch {
            presentAlert(String(localized: "Failed to rename"), error.localizedDescription)
            return nil
        }
    }

    /// Update every URL-keyed piece of state when a path on disk moves
    /// from `old` to `new`.  Called by rename/move/paste.
    private func translateURL(from old: URL, to new: URL) {
        let oldStd = old.standardizedFileURL
        let newStd = new.standardizedFileURL
        if currentFileURL?.standardizedFileURL == oldStd {
            currentFileURL = new
        }
        if selection.contains(oldStd) {
            selection.remove(oldStd)
            selection.insert(newStd)
        }
        if anchorURL?.standardizedFileURL == oldStd {
            anchorURL = newStd
        }
        if var clip = clipboard {
            clip.urls = clip.urls.map { $0.standardizedFileURL == oldStd ? newStd : $0 }
            clipboard = clip
        }
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
                if currentFileURL?.standardizedFileURL == url {
                    trashedOpenDoc = true
                }
                selection.remove(url)
                if anchorURL?.standardizedFileURL == url { anchorURL = nil }
                if var clip = clipboard {
                    clip.urls.removeAll { $0.standardizedFileURL == url }
                    clipboard = clip.urls.isEmpty ? nil : clip
                }
                DebugLog.write("[fileop] trashed \(url.lastPathComponent)")
            } catch {
                DebugLog.write("[fileop] trash FAILED \(url.lastPathComponent): \(error.localizedDescription)")
                presentAlert(String(localized: "Failed to move to Trash"), error.localizedDescription)
            }
        }
        if trashedOpenDoc {
            cancelPendingAutoSave()
            untitledAutosaveName = nil
            beginPriming()
            currentFileURL = nil
            currentMarkdown = ""
            localImageAuthNeeded = false
            isDirty = false
            loadEpoch += 1
        }
        rebuildFileTree()
    }

    /// Delete every URL currently in `selection`.  Used by the Delete key
    /// and the Edit menu's "Delete Selection" command.
    func deleteSelection() {
        delete(Array(selection))
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
            if Self.contains(parent: srcStd, child: destStd) {
                NSSound.beep()
                DebugLog.write("[fileop] move refused (cycle): \(srcStd.lastPathComponent) → \(destStd.path)")
                return []
            }
        }

        beginInternalMutation()
        var newURLs: [URL] = []
        for src in urls {
            let dest = uniqueURL(in: destination, name: src.lastPathComponent)
            do {
                try FileManager.default.moveItem(at: src, to: dest)
                translateURL(from: src, to: dest)
                newURLs.append(dest)
                DebugLog.write("[fileop] move \(src.lastPathComponent) → \(dest.path)")
            } catch {
                DebugLog.write("[fileop] move FAILED \(src.lastPathComponent): \(error.localizedDescription)")
                presentAlert(String(localized: "Failed to move"), error.localizedDescription)
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
            let dest = uniqueURL(in: destination, name: src.lastPathComponent)
            do {
                try FileManager.default.copyItem(at: src, to: dest)
                newURLs.append(dest)
                DebugLog.write("[fileop] copy \(src.lastPathComponent) → \(dest.path)")
            } catch {
                DebugLog.write("[fileop] copy FAILED \(src.lastPathComponent): \(error.localizedDescription)")
                presentAlert(String(localized: "Failed to copy"), error.localizedDescription)
            }
        }
        rebuildFileTree()
        return newURLs
    }

    /// Mark the current selection for a Cut operation.  Items render at
    /// 50% opacity in the sidebar until pasted or another clipboard op
    /// replaces them.
    func cutSelection() {
        guard !selection.isEmpty else { return }
        clipboard = SidebarClipboard(urls: Array(selection), op: .cut)
        DebugLog.write("[sidebar] cut \(selection.count) items")
    }

    /// Mark the current selection for a Copy operation.
    func copySelection() {
        guard !selection.isEmpty else { return }
        clipboard = SidebarClipboard(urls: Array(selection), op: .copy)
        DebugLog.write("[sidebar] copy \(selection.count) items")
    }

    /// Consume `self.clipboard` into the destination directory.
    /// `into == nil` → resolve to a sensible default: single-selected
    /// folder → that folder; selected file → its parent; otherwise →
    /// workspace root.
    func paste(into requestedDest: URL?) {
        guard let clip = clipboard else { return }
        let dest = requestedDest ?? defaultPasteDestination()
        guard let dest else { return }
        switch clip.op {
        case .cut:
            let newURLs = move(clip.urls, into: dest)
            if !newURLs.isEmpty {
                clipboard = nil
                selection = Set(newURLs.map { $0.standardizedFileURL })
            }
        case .copy:
            let newURLs = copy(clip.urls, into: dest)
            if !newURLs.isEmpty {
                selection = Set(newURLs.map { $0.standardizedFileURL })
            }
        }
    }

    /// Workspace root if no selection, else the parent of the first
    /// selected item (or the item itself if it's a folder).
    private func defaultPasteDestination() -> URL? {
        if selection.count == 1, let only = selection.first {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: only.path, isDirectory: &isDir), isDir.boolValue {
                return only
            }
            return only.deletingLastPathComponent()
        }
        return folderURL
    }

    // MARK: - Selection helpers

    /// Plain click semantics: select only this URL, set anchor, and
    /// load the file into the editor if it's a file (folders just
    /// toggle their own expansion state in the caller).
    func selectOnly(_ url: URL, loadIfFile: Bool = true) {
        let std = url.standardizedFileURL
        selection = [std]
        anchorURL = std
        if loadIfFile {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
               !isDir.boolValue,
               currentFileURL?.standardizedFileURL != std {
                loadFile(url)
            }
        }
    }

    /// ⌘+click semantics: toggle membership in selection without
    /// changing the editor's open document.  Sets anchor on add.
    func toggleSelection(_ url: URL) {
        let std = url.standardizedFileURL
        if selection.contains(std) {
            selection.remove(std)
            if anchorURL == std { anchorURL = nil }
        } else {
            selection.insert(std)
            anchorURL = std
        }
    }

    /// Shift+click semantics: extend `selection` from `anchorURL` to
    /// `url` along the visible row order.  No-op if anchor is nil
    /// (falls back to plain click).
    func extendSelection(to url: URL, visibleOrder: [URL]) {
        let std = url.standardizedFileURL
        guard let anchor = anchorURL?.standardizedFileURL else {
            selectOnly(url)
            return
        }
        let standardised = visibleOrder.map { $0.standardizedFileURL }
        guard let i = standardised.firstIndex(of: anchor),
              let j = standardised.firstIndex(of: std) else {
            selectOnly(url)
            return
        }
        let lo = min(i, j)
        let hi = max(i, j)
        selection = Set(standardised[lo...hi])
    }

    /// Clear all multi-selection but keep the editor's open document
    /// alone — clicking the empty sidebar background does this.
    func clearSelection() {
        selection.removeAll()
        anchorURL = nil
    }

    /// Compute the flat top-to-bottom visible URL order from the file
    /// tree given the set of expanded folder URLs.  Used by Shift+click
    /// range selection.
    func flattenedVisibleURLs(expanded: Set<URL>) -> [URL] {
        var result: [URL] = []
        func walk(_ nodes: [FileNode]) {
            for node in nodes {
                result.append(node.url)
                if node.isDirectory, expanded.contains(node.url) {
                    walk(node.children)
                }
            }
        }
        walk(fileTree)
        return result
    }

    // (Path containment helper `Self.contains(parent:, child:)` is defined
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

    /// Resolve where pasted-image bytes for `fileURL` should be stored.
    /// Returns a security-scoped URL the caller can read/write inside.
    ///
    /// Priority:
    /// 1. File inside the active workspace → workspace root.
    /// 2. File outside any workspace, but its parent dir has an existing
    ///    grant → that grant.
    /// 3. Untitled (nil fileURL) and a workspace exists → workspace root.
    /// 4. No workspace, no grant → nil (caller must prompt or reject).
    func imageScope(for fileURL: URL?) -> URL? {
        if let fileURL, let folder = folderURL,
           Self.contains(parent: folder, child: fileURL) {
            return folder
        }
        if let fileURL {
            return DocumentDirBookmarks.grant(for: fileURL)
        }
        return folderURL
    }

    // MARK: - Local image folder access

    /// Prompt for read access to the open document's folder, then re-pull the
    /// document so its now-readable local images render.  Invoked by the
    /// "Allow Access" banner.  No-op without a current file or if the user
    /// cancels the folder picker.
    func authorizeCurrentDocumentFolder() {
        guard let fileURL = currentFileURL else { return }
        let granted = DocumentDirBookmarks.requestGrant(
            for: fileURL,
            message: String(
                format: String(localized: "Allow Notation to read the folder containing “%@” so this document’s local images can be displayed."),
                fileURL.lastPathComponent
            ),
            prompt: String(localized: "Allow Access")
        )
        guard granted != nil else { return }
        localImageAuthNeeded = false
        // Re-pull: EditorWebView.updateNSView refreshes the scheme handler's
        // grants (picking up the new bookmark) before re-sending the markdown,
        // so the images resolve on re-render.  Prime so BlockNote's
        // post-replaceBlocks onChange echo doesn't masquerade as a user edit.
        beginPriming()
        loadEpoch += 1
    }

    /// Decide whether to surface the local-image access banner for a freshly
    /// loaded document.  Cheap checks first (workspace containment, then a
    /// non-starting bookmark peek); only scan the markdown for a local image
    /// reference when the folder isn't already readable.
    private func computeLocalImageAuthNeeded(for fileURL: URL, markdown: String) -> Bool {
        if let folder = folderURL, Self.contains(parent: folder, child: fileURL) { return false }
        if DocumentDirBookmarks.hasGrant(for: fileURL) { return false }
        return Self.markdownReferencesLocalImage(markdown)
    }

    /// True if `markdown` contains an image whose target is a local path
    /// (relative or absolute) rather than a remote / `data:` / in-app URL.
    /// Only used to decide whether the access banner is worth showing, so a
    /// permissive match is fine.
    static func markdownReferencesLocalImage(_ markdown: String) -> Bool {
        let patterns = [
            #"!\[[^\]]*\]\(\s*([^)\s]+)"#,                 // ![alt](path "title")
            #"<img[^>]*\bsrc\s*=\s*["']([^"']+)["']"#      // <img src="path">
        ]
        let ns = markdown as NSString
        let full = NSRange(location: 0, length: ns.length)
        for pattern in patterns {
            guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            for m in re.matches(in: markdown, range: full) where m.numberOfRanges > 1 {
                let ref = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces)
                if isLocalImageReference(ref) { return true }
            }
        }
        return false
    }

    private static func isLocalImageReference(_ ref: String) -> Bool {
        guard !ref.isEmpty else { return false }
        let lower = ref.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") { return false }
        if lower.hasPrefix("data:") { return false }
        if lower.hasPrefix("marktext-editor:") { return false }
        return true
    }

    /// Equivalent path-containment check used by `imageScope` and
    /// `DocumentDirBookmarks`.  Standardises paths first so `~/Foo/../Bar`
    /// reduces correctly, and gates on the trailing-slash boundary so
    /// `/Foo` doesn't match `/FooBar/x`.
    static func contains(parent: URL, child: URL) -> Bool {
        let parentPath = parent.standardizedFileURL.path
        let childPath = child.standardizedFileURL.path
        if parentPath == childPath { return true }
        let needle = parentPath.hasSuffix("/") ? parentPath : parentPath + "/"
        return childPath.hasPrefix(needle)
    }

    private func sanitizedExtension(_ ext: String) -> String {
        let trimmed = ext.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed = trimmed.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) }
        if !trimmed.isEmpty, allowed, trimmed.count <= 6 { return trimmed }
        return "png"
    }

    // MARK: - Filesystem helpers

    /// Collision-avoiding URL: returns `dir/name` if free, else appends
    /// `" 2"`, `" 3"`, ... preserving the extension.  Internal so the
    /// move/copy/paste paths can reuse it without duplicating logic.
    func uniqueURL(in dir: URL, name: String) -> URL {
        let base = dir.appendingPathComponent(name)
        if !FileManager.default.fileExists(atPath: base.path) { return base }
        let stem = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        for i in 2...999 {
            let candidate = dir.appendingPathComponent(
                ext.isEmpty ? "\(stem) \(i)" : "\(stem) \(i).\(ext)"
            )
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return base
    }

    private func promptForName(title: String, placeholder: String, defaultValue: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.alertStyle = .informational
        alert.addButton(withTitle: String(localized: "OK"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = placeholder
        field.stringValue = defaultValue
        // Select stem so ".md" extension survives unless user replaces all.
        if let editor = field.currentEditor() as? NSTextView {
            editor.selectAll(nil)
        }
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return nil }
        return field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
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
            } else if isMarkdown(entry) {
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

    private func isMarkdown(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ["md", "markdown", "mdown", "mkd"].contains(ext)
    }

    private func markdownTypes() -> [UTType] {
        var types: [UTType] = [.plainText]
        if let md = UTType(filenameExtension: "md") { types.append(md) }
        if let mk = UTType(filenameExtension: "markdown") { types.append(mk) }
        return types
    }
}
