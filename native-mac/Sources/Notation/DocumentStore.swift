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

    init() {
        // First-launch-after-install: ask macOS to make Notation the
        // default handler for .md files.  Idempotent — the helper tracks a
        // flag in UserDefaults so we only do it once.
        DefaultMarkdownHandler.claimAsDefaultIfNeeded()
    }

    // Called by JS bridge whenever editor content changes.
    func handleEditorChange(_ markdown: String) {
        currentMarkdown = markdown
        isDirty = true
        scheduleAutoSave()
    }

    private func scheduleAutoSave() {
        autoSaveTask?.cancel()
        let defaults = UserDefaults.standard
        let enabled = defaults.bool(forKey: "autoSaveEnabled")
        guard enabled, currentFileURL != nil else { return }
        let delay = defaults.double(forKey: "autoSaveDelaySeconds")
        let seconds = delay > 0 ? delay : 2.0
        autoSaveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            if self.isDirty, self.currentFileURL != nil {
                self.save()
            }
        }
    }

    func newDocument() {
        guard confirmDiscardIfDirty() else { return }
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
            currentFileURL = url
            currentMarkdown = content
            isDirty = false
            loadEpoch += 1
            RecentFiles.shared.push(url)
        } catch {
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
        }
    }

    private func writeMarkdown(to url: URL) {
        do {
            try currentMarkdown.write(to: url, atomically: true, encoding: .utf8)
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

    func rename(_ url: URL) {
        guard let newName = promptForName(
            title: String(localized: "Rename"),
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
            presentAlert(String(localized: "Failed to rename"), error.localizedDescription)
        }
    }

    func delete(_ url: URL) {
        let alert = NSAlert()
        let fileName = url.lastPathComponent
        alert.messageText = String(localized: "Move “\(fileName)” to the Trash?")
        alert.informativeText = String(localized: "You can restore it from the Trash if needed.")
        alert.alertStyle = .warning
        alert.addButton(withTitle: String(localized: "Move to Trash"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            if currentFileURL == url {
                currentFileURL = nil
                currentMarkdown = ""
                isDirty = false
                loadEpoch += 1
            }
            rebuildFileTree()
        } catch {
            presentAlert(String(localized: "Failed to move to Trash"), error.localizedDescription)
        }
    }

    func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
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
