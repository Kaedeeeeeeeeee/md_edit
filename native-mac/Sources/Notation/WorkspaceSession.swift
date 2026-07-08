import Foundation
import Observation
import AppKit

struct FileNode: Identifiable, Hashable {
    var id: String { url.path }
    let url: URL
    let name: String
    let documentTitle: String?
    let isDirectory: Bool
    let children: [FileNode]
}

enum MarkdownDocumentTitle {
    private static let maxScanBytes = 64 * 1024
    private static let maxScanCharacters = 64 * 1024
    private static let maxTitleCharacters = 180
    private static let maxFileStemCharacters = 80

    static func title(fromFileAt url: URL) -> String? {
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let data = try handle.read(upToCount: maxScanBytes) ?? Data()
            guard !data.isEmpty else { return nil }
            let markdown = String(decoding: data, as: UTF8.self)
            return title(fromMarkdown: markdown)
        } catch {
            return nil
        }
    }

    static func title(fromMarkdown markdown: String) -> String? {
        let prefix = String(markdown.prefix(maxScanCharacters))
        for rawLine in prefix.components(separatedBy: .newlines) {
            if let title = normalizedTitleLine(rawLine) {
                return title
            }
        }
        return nil
    }

    static func syncedFileName(fromMarkdown markdown: String, fallbackExtension: String) -> String? {
        guard let title = title(fromMarkdown: markdown),
              var stem = sanitizedFileStem(fromTitle: title) else {
            return nil
        }
        if stem.count > maxFileStemCharacters {
            stem = String(stem.prefix(maxFileStemCharacters))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !stem.isEmpty else { return nil }
        let ext = fallbackExtension.isEmpty ? "md" : fallbackExtension
        return "\(stem).\(ext)"
    }

    private static func normalizedTitleLine(_ rawLine: String) -> String? {
        var title = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }

        title = stripBlockquotePrefix(title)
        title = stripHeadingPrefix(title)
        title = stripListPrefix(title)
        title = stripWrappingEmphasis(title)
        title = title.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !title.isEmpty else { return nil }
        if title.count > maxTitleCharacters {
            return String(title.prefix(maxTitleCharacters))
        }
        return title
    }

    private static func stripBlockquotePrefix(_ text: String) -> String {
        var title = text
        while title.hasPrefix(">") {
            title = String(title.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return title
    }

    private static func stripHeadingPrefix(_ text: String) -> String {
        let hashes = text.prefix { $0 == "#" }
        guard (1...6).contains(hashes.count) else { return text }
        let rest = text.dropFirst(hashes.count)
        guard rest.first?.isWhitespace == true else { return text }
        return String(rest)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(
                of: #"\s+#+\s*$"#,
                with: "",
                options: .regularExpression
            )
    }

    private static func stripListPrefix(_ text: String) -> String {
        text
            .replacingOccurrences(
                of: #"^[-*+]\s+\[[ xX]\]\s+"#,
                with: "",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"^[-*+]\s+"#,
                with: "",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"^\d+[.)]\s+"#,
                with: "",
                options: .regularExpression
            )
    }

    private static func stripWrappingEmphasis(_ text: String) -> String {
        for token in ["**", "__", "*", "_", "`"] {
            if text.hasPrefix(token), text.hasSuffix(token), text.count > token.count * 2 {
                return String(text.dropFirst(token.count).dropLast(token.count))
            }
        }
        return text
    }

    private static func sanitizedFileStem(fromTitle title: String) -> String? {
        let invalidScalars = CharacterSet(charactersIn: "/:")
            .union(.controlCharacters)
            .union(.newlines)
        var stem = ""
        for scalar in title.unicodeScalars {
            if invalidScalars.contains(scalar) {
                stem.append("-")
            } else {
                stem.unicodeScalars.append(scalar)
            }
        }
        let trimScalars = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "."))
        stem = stem
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"-{2,}"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: trimScalars)
        if stem == "." || stem == ".." { return nil }
        return stem.isEmpty ? nil : stem
    }
}

/// The active workspace: a folder on disk, its scanned Markdown tree,
/// the FSEvents watcher, and every filesystem mutation (create, rename,
/// move, copy, trash, attachment writes).
///
/// Split out of the old `DocumentStore` god object (B2 refactor, phase 1).
/// Deliberately knows nothing about the open document or the sidebar
/// selection: mutating operations return what actually happened
/// (moved pairs, trashed URLs) and the owning coordinator applies the
/// side effects to `DocumentSession` / `SidebarState`.  Workspace
/// *persistence* (security-scoped bookmarks, recents) also stays with
/// the owner — this type only holds the live scope handle it started.
@MainActor
@Observable
final class WorkspaceSession {
    private(set) var folderURL: URL?
    private(set) var fileTree: [FileNode] = []

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

    // MARK: - Adoption / watching

    /// Set the active workspace folder and refresh the file tree.
    /// Caller is responsible for having started access on `url` if it came
    /// from a security-scoped bookmark.
    func adopt(_ url: URL) {
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
    private func handleExternalFolderChange() {
        if let suppress = suppressWatcherUntil, Date() < suppress { return }
        rebuildFileTree()
    }

    /// Quiet the FolderWatcher for ~0.4s while an internal batch finishes.
    private func beginInternalMutation() {
        suppressWatcherUntil = Date().addingTimeInterval(0.4)
    }

    // MARK: - File operations

    /// Create a new empty .md file inside `parent` (workspace root if
    /// nil), prompting for the name.  Returns the created URL on success.
    /// Does NOT open it — the coordinator decides what "created" means
    /// for the editor.
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

    /// Rename `url` to `newName` (last-path-component only — full paths
    /// are rejected).  Returns the new URL on success, `url` itself on a
    /// same-name no-op, or nil on failure.  Handles empty/illegal names,
    /// collisions (via `FilePaths.uniqueURL`), and watcher suppression.
    /// The caller translates any state keyed on the old URL.
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

        let parent = url.deletingLastPathComponent()
        let dest = FilePaths.uniqueURL(in: parent, name: trimmed)

        beginInternalMutation()
        do {
            try FileManager.default.moveItem(at: url, to: dest)
            rebuildFileTree()
            DebugLog.write("[fileop] rename \(url.lastPathComponent) -> \(dest.lastPathComponent)")
            return dest
        } catch {
            AppAlerts.present(String(localized: "Failed to rename"), error.localizedDescription)
            return nil
        }
    }

    /// Move already-confirmed URLs to the system Trash.  Returns the
    /// standardised URLs actually trashed; failures alert individually
    /// and are skipped.  Confirmation UI and cleanup of state that
    /// referenced the trashed paths belong to the caller.
    func trash(_ urls: [URL]) -> [URL] {
        guard !urls.isEmpty else { return [] }
        beginInternalMutation()
        var trashed: [URL] = []
        for url in urls.map({ $0.standardizedFileURL }) {
            do {
                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                trashed.append(url)
                DebugLog.write("[fileop] trashed \(url.lastPathComponent)")
            } catch {
                DebugLog.write("[fileop] trash FAILED \(url.lastPathComponent): \(error.localizedDescription)")
                AppAlerts.present(String(localized: "Failed to move to Trash"), error.localizedDescription)
            }
        }
        rebuildFileTree()
        return trashed
    }

    /// Move N URLs into `destination` (a folder).  Same-volume → rename
    /// (via `FileManager.moveItem`).  Cross-volume → copy + remove
    /// (matches Finder semantics).  Refuses to move a folder into itself
    /// or its descendant.  Returns the (from, to) pairs that succeeded so
    /// the caller can translate URL-keyed state.
    func move(_ urls: [URL], into destination: URL) -> [(from: URL, to: URL)] {
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
        var moved: [(from: URL, to: URL)] = []
        for src in urls {
            let dest = FilePaths.uniqueURL(in: destination, name: src.lastPathComponent)
            do {
                try FileManager.default.moveItem(at: src, to: dest)
                moved.append((from: src, to: dest))
                DebugLog.write("[fileop] move \(src.lastPathComponent) → \(dest.path)")
            } catch {
                DebugLog.write("[fileop] move FAILED \(src.lastPathComponent): \(error.localizedDescription)")
                AppAlerts.present(String(localized: "Failed to move"), error.localizedDescription)
            }
        }
        rebuildFileTree()
        return moved
    }

    /// Recursively copy N URLs into `destination`.  Collisions resolved
    /// via `FilePaths.uniqueURL`.  Nothing to translate — the originals
    /// are still there.
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
                    documentTitle: nil,
                    isDirectory: true,
                    children: children
                ))
            } else if FilePaths.isMarkdown(entry) {
                nodes.append(FileNode(
                    url: entry,
                    name: entry.lastPathComponent,
                    documentTitle: MarkdownDocumentTitle.title(fromFileAt: entry),
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
