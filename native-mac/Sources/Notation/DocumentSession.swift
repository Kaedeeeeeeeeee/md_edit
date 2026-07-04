import Foundation
import Observation
import AppKit
import UniformTypeIdentifiers

/// The lifecycle of one open document: content, dirty tracking, autosave,
/// encoding preservation, and the local-image authorization probe.
///
/// Split out of the old `DocumentStore` god object (B2 refactor, phase 1).
/// One instance backs the main window today; in phase 2 every document
/// window gets its own, which is why all workspace knowledge enters
/// through two injected hooks instead of a store reference:
///
///   - `workspaceRoot`: where untitled autosaves land and what counts as
///     "inside the workspace" for image-scope decisions.  Document
///     windows will inject `{ nil }`.
///   - `onFileWritten`: owner refreshes whatever it must after a write
///     lands on disk (today: rebuild the sidebar tree).
@MainActor
@Observable
final class DocumentSession {
    var currentFileURL: URL?
    var currentMarkdown: String = ""
    var isDirty: Bool = false

    /// Monotonically increments every time the editor should re-pull
    /// content from this session (file open, new document, current file
    /// deleted).  Editor-originated edits do NOT bump this — that would
    /// loop back.  EditorWebView observes it and pushes `currentMarkdown`
    /// into JS when it changes.
    var loadEpoch: Int = 0

    /// True when the open document references a local image but lives in
    /// a folder Notation hasn't been granted read access to — i.e. a
    /// single file opened from outside the workspace, before any folder
    /// authorisation.  Drives the non-blocking "Allow Access" banner.
    /// Computed once per `loadFile` (never as a hot property — the
    /// readability probe touches security-scoped bookmarks).
    var localImageAuthNeeded: Bool = false

    // MARK: - Owner wiring

    /// The active workspace root, if any.  Injected by the owner.
    @ObservationIgnored var workspaceRoot: () -> URL? = { nil }

    /// Invoked after markdown bytes land on disk (explicit save, autosave,
    /// untitled autosave) so the owner can refresh dependent state.
    @ObservationIgnored var onFileWritten: (URL) -> Void = { _ in }

    // MARK: - Private state

    private var autoSaveTask: Task<Void, Never>?

    /// Once auto-save has chosen a filename for an untitled document,
    /// reuse it for subsequent autosaves in the same session.  Cleared on
    /// `newDocument()` / `loadFile()`.  Without this, rapid edits after
    /// the timestamp tick boundary spawn multiple `Untitled-…` files.
    private var untitledAutosaveName: String?

    /// Encoding detected when we last `loadFile`d.  Preserved on save so
    /// opening a UTF-16 / GB18030 file and saving it doesn't silently
    /// transcode the user's bytes to UTF-8.
    private var currentFileEncoding: String.Encoding = .utf8

    /// Suppress `handleEditorChange` while we're pushing a freshly-loaded
    /// document into the editor.  BlockNote re-emits an onChange post-
    /// `replaceBlocks` with its own normalised markdown (trailing
    /// newlines, whitespace), which without this flag would mark the doc
    /// dirty the instant it loads and silently trigger autosave to a
    /// normalised form that rewrites the user's file or spawns a phantom
    /// Untitled.
    @ObservationIgnored private var isPriming: Bool = false
    @ObservationIgnored private var primingTask: Task<Void, Never>?

    // MARK: - Editor change / autosave

    /// Called by the JS bridge whenever editor content changes.
    func handleEditorChange(_ markdown: String) {
        if isPriming {
            // Editor's first onChange after replaceBlocks is BlockNote's
            // own normalisation, not user input.  Track the markdown so
            // dirty detection has the right baseline, but don't flip dirty.
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
    /// fires after `currentFileURL` and `currentMarkdown` have been
    /// swapped, either zombie-writing discarded content or stomping on
    /// freshly-loaded content with stale data.
    func cancelPendingAutoSave() {
        autoSaveTask?.cancel()
        autoSaveTask = nil
    }

    /// Open a 1-second window during which `handleEditorChange` only
    /// updates the cached markdown and does not flip dirty / schedule
    /// autosave.  Callers invoke this immediately before triggering an
    /// editor re-render so BlockNote's normalisation echo doesn't
    /// masquerade as user input.
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
            } else if self.workspaceRoot() != nil {
                self.autosaveAsUntitled()
            }
            // If both are nil (no vault, no file), nothing we can do
            // safely.  After phase-2 onboarding a workspace always
            // exists, so this branch is effectively unreachable.
        }
    }

    /// Persist an untitled document into the active workspace using a
    /// timestamped filename, then promote it to `currentFileURL` so
    /// subsequent saves go through the standard path.
    private func autosaveAsUntitled() {
        guard let folder = workspaceRoot() else { return }
        if untitledAutosaveName == nil {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd-HH-mm-ss"
            untitledAutosaveName = "Untitled-\(formatter.string(from: Date())).md"
        }
        guard let name = untitledAutosaveName else { return }
        let target = FilePaths.uniqueURL(in: folder, name: name)
        do {
            try currentMarkdown.write(to: target, atomically: true, encoding: .utf8)
            currentFileURL = target
            isDirty = false
            RecentFiles.shared.push(target)
            onFileWritten(target)
            DebugLog.write("[autosave] created untitled \(target.lastPathComponent)")
        } catch {
            DebugLog.write("[autosave] untitled write failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Open / new / reset

    func newDocument() {
        guard confirmDiscardIfDirty() else { return }
        reset()
    }

    /// Blank the session and bump the epoch so the editor re-pulls.
    /// Called directly (without the discard prompt) when the open file
    /// was moved to the Trash out from under us.
    func reset() {
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

    func loadFile(_ url: URL) {
        do {
            // Size guard — refuse files >20 MB so a stray log file can't
            // pin the main thread on String(contentsOf:) or OOM the
            // WKWebView when we splice the doc into evaluateJavaScript.
            let resourceValues = try url.resourceValues(forKeys: [.fileSizeKey])
            if let size = resourceValues.fileSize, size > 20 * 1024 * 1024 {
                let sizeStr = ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
                AppAlerts.present(
                    String(localized: "File too large"),
                    String(format: String(localized: "Notation can open Markdown files up to 20 MB. This file is %@."), sizeStr)
                )
                return
            }
            // Auto-detect encoding — handles UTF-8 BOM, UTF-16 BE/LE BOM,
            // system default fallback.  Remember the encoding so
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
            AppAlerts.present(String(localized: "Failed to open file"), error.localizedDescription)
        }
    }

    /// Keep `currentFileURL` in sync when the open file is renamed or
    /// moved on disk by a sidebar file operation.
    func noteFileMoved(from old: URL, to new: URL) {
        if currentFileURL?.standardizedFileURL == old.standardizedFileURL {
            currentFileURL = new
        }
    }

    // MARK: - Save

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
            onFileWritten(url)
        } catch {
            AppAlerts.present(String(localized: "Failed to save"), error.localizedDescription)
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

    // MARK: - Image scope (paste target resolution)

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
        if let fileURL, let folder = workspaceRoot(),
           FilePaths.contains(parent: folder, child: fileURL) {
            return folder
        }
        if let fileURL {
            return DocumentDirBookmarks.grant(for: fileURL)
        }
        return workspaceRoot()
    }

    // MARK: - Local image folder access

    /// Prompt for read access to the open document's folder, then re-pull
    /// the document so its now-readable local images render.  Invoked by
    /// the "Allow Access" banner.  No-op without a current file or if the
    /// user cancels the folder picker.
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
        // Re-pull: EditorWebView.updateNSView refreshes the scheme
        // handler's grants (picking up the new bookmark) before re-sending
        // the markdown, so the images resolve on re-render.  Prime so
        // BlockNote's post-replaceBlocks onChange echo doesn't masquerade
        // as a user edit.
        beginPriming()
        loadEpoch += 1
    }

    /// Decide whether to surface the local-image access banner for a
    /// freshly loaded document.  Cheap checks first (workspace
    /// containment, then a non-starting bookmark peek); only scan the
    /// markdown for a local image reference when the folder isn't already
    /// readable.
    private func computeLocalImageAuthNeeded(for fileURL: URL, markdown: String) -> Bool {
        if let folder = workspaceRoot(), FilePaths.contains(parent: folder, child: fileURL) {
            return false
        }
        if DocumentDirBookmarks.hasGrant(for: fileURL) { return false }
        return Self.markdownReferencesLocalImage(markdown)
    }

    /// True if `markdown` contains an image whose target is a local path
    /// (relative or absolute) rather than a remote / `data:` / in-app
    /// URL.  Only used to decide whether the access banner is worth
    /// showing, so a permissive match is fine.
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

    // MARK: - Helpers

    private func markdownTypes() -> [UTType] {
        var types: [UTType] = [.plainText]
        if let md = UTType(filenameExtension: "md") { types.append(md) }
        if let mk = UTType(filenameExtension: "markdown") { types.append(mk) }
        return types
    }
}
