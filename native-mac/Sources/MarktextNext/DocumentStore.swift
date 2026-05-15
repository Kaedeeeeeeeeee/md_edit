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

    private var autoSaveTask: Task<Void, Never>?
    private let folderWatcher = FolderWatcher()
    private var folderWatcherWired = false

    /// Once auto-save has chosen a filename for an untitled document, reuse it
    /// for subsequent autosaves in the same session.  Cleared on
    /// `newDocument()` / `loadFile()`.  Without this, rapid edits after the
    /// timestamp tick boundary spawn multiple `Untitled-…` files.
    private var untitledAutosaveName: String?

    /// Suppress `handleEditorChange` while we're pushing a freshly-loaded
    /// document into the editor.  BlockNote re-emits an onChange post-
    /// `replaceBlocks` with its own normalised markdown (trailing newlines,
    /// whitespace), which without this flag would mark the doc dirty the
    /// instant it loads and silently trigger autosave to a normalised form
    /// that rewrites the user's file or spawns a phantom Untitled.
    @ObservationIgnored private var isPriming: Bool = false
    @ObservationIgnored private var primingTask: Task<Void, Never>?

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

        // First-launch-after-install: ask macOS to make Marktext Next the
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
        if panel.runModal() == .OK, let url = panel.url {
            adoptFolder(url)
            WorkspaceBookmark.save(url)
        }
    }

    /// Set the active workspace folder and refresh the file tree.
    /// Caller is responsible for having started access on `url` if it came
    /// from a security-scoped bookmark.
    func adoptFolder(_ url: URL) {
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
    func handleExternalFolderChange() {
        rebuildFileTree()
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
            let content = try String(contentsOf: url, encoding: .utf8)
            cancelPendingAutoSave()
            untitledAutosaveName = nil
            beginPriming()
            currentFileURL = url
            currentMarkdown = content
            isDirty = false
            loadEpoch += 1
            RecentFiles.shared.push(url)
        } catch {
            presentAlert("Failed to open file", error.localizedDescription)
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
            try currentMarkdown.write(to: url, atomically: true, encoding: .utf8)
            isDirty = false
            RecentFiles.shared.push(url)
            if folderURL != nil { rebuildFileTree() }
        } catch {
            presentAlert("Failed to save", error.localizedDescription)
        }
    }

    private func confirmDiscardIfDirty() -> Bool {
        guard isDirty else { return true }
        let alert = NSAlert()
        alert.messageText = "You have unsaved changes."
        alert.informativeText = "Discard them and continue?"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Cancel")
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
            title: "New File",
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
            presentAlert("Failed to create file", error.localizedDescription)
            return nil
        }
    }

    @discardableResult
    func createNewFolder(in parent: URL? = nil) -> URL? {
        let dir = parent ?? folderURL
        guard let dir else { return nil }
        guard let name = promptForName(
            title: "New Folder",
            placeholder: "Untitled Folder",
            defaultValue: "Untitled Folder"
        ), !name.isEmpty else { return nil }
        let url = uniqueURL(in: dir, name: name)
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            rebuildFileTree()
            return url
        } catch {
            presentAlert("Failed to create folder", error.localizedDescription)
            return nil
        }
    }

    func rename(_ url: URL) {
        guard let newName = promptForName(
            title: "Rename",
            placeholder: url.lastPathComponent,
            defaultValue: url.lastPathComponent
        ), !newName.isEmpty, newName != url.lastPathComponent else { return }
        let dest = url.deletingLastPathComponent().appendingPathComponent(newName)
        do {
            try FileManager.default.moveItem(at: url, to: dest)
            if currentFileURL == url {
                currentFileURL = dest
            }
            rebuildFileTree()
        } catch {
            presentAlert("Failed to rename", error.localizedDescription)
        }
    }

    func delete(_ url: URL) {
        let alert = NSAlert()
        alert.messageText = "Move “\(url.lastPathComponent)” to the Trash?"
        alert.informativeText = "You can restore it from the Trash if needed."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            if currentFileURL == url {
                cancelPendingAutoSave()
                untitledAutosaveName = nil
                beginPriming()
                currentFileURL = nil
                currentMarkdown = ""
                isDirty = false
                loadEpoch += 1
            }
            rebuildFileTree()
        } catch {
            presentAlert("Failed to move to Trash", error.localizedDescription)
        }
    }

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

    private func uniqueURL(in dir: URL, name: String) -> URL {
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
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
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
                let children = scanFolder(entry)
                if !children.isEmpty {
                    nodes.append(FileNode(
                        url: entry,
                        name: entry.lastPathComponent,
                        isDirectory: true,
                        children: children
                    ))
                }
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
