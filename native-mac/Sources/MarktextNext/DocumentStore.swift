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

    /// Set by `EditorWebView` once mounted. Sends a markdown string into the
    /// embedded BlockNote editor via JS bridge.
    var loadIntoEditor: ((String) -> Void)?

    private var autoSaveTask: Task<Void, Never>?

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
        loadIntoEditor?("")
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
            folderURL = url
            rebuildFileTree()
        }
    }

    func loadFile(_ url: URL) {
        do {
            let content = try String(contentsOf: url, encoding: .utf8)
            currentFileURL = url
            currentMarkdown = content
            isDirty = false
            loadIntoEditor?(content)
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
