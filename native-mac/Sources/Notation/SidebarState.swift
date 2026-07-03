import Foundation
import Observation

/// Pasteboard-like state so menu-bar commands and the sidebar context menu
/// can coordinate Cut/Copy/Paste across the whole window.  When
/// `op == .cut`, the rows render at half opacity so the user remembers
/// they have a pending move.
struct SidebarClipboard: Equatable {
    enum Op { case cut, copy }
    var urls: [URL]
    var op: Op
}

/// Sidebar UI state — selection, clipboard, disclosed folders.
///
/// Split out of the old `DocumentStore` god object (B2 refactor, phase 1):
/// none of this is document or filesystem state, it's purely "what the
/// tree looks like right now".  File operations keep it consistent via
/// `translate(from:to:)` / `remove(_:)`; it never touches disk itself and
/// never loads documents — coordination like "click selects AND opens"
/// lives on the owner.
///
/// All URLs are stored standardised so `Set` membership is stable.
@MainActor
@Observable
final class SidebarState {
    /// Multi-selection used by the sidebar UI for batch operations
    /// (delete, drag-drop, cut/copy/paste).  Overlaps `currentFileURL`
    /// when the user clicks one file; diverges when the user ⌘-clicks to
    /// add files without changing the editor.
    var selection: Set<URL> = []

    /// Anchor for Shift+click range selection — the URL of the last row
    /// the user clicked without holding ⌘.  Nil after `clear()`.
    var anchorURL: URL?

    /// Cut/Copy pasteboard, consumed by the owner's `paste(into:)`.
    var clipboard: SidebarClipboard?

    /// Folder rows currently disclosed in the tree.  Historically a
    /// `@State` on SidebarView; owned here so Shift+click range selection
    /// (which walks the *visible* row order) doesn't need view plumbing,
    /// and future "reveal file in sidebar" flows can expand ancestors.
    var expanded: Set<URL> = []

    // MARK: - Selection mechanics

    /// Plain click semantics: select only this URL and set the anchor.
    func selectOnly(_ url: URL) {
        let std = url.standardizedFileURL
        selection = [std]
        anchorURL = std
    }

    /// ⌘+click semantics: toggle membership without touching other rows.
    /// Sets anchor on add.
    func toggle(_ url: URL) {
        let std = url.standardizedFileURL
        if selection.contains(std) {
            selection.remove(std)
            if anchorURL == std { anchorURL = nil }
        } else {
            selection.insert(std)
            anchorURL = std
        }
    }

    /// Shift+click semantics: extend from `anchorURL` to `url` along the
    /// visible row order.  Falls back to plain click when there's no
    /// anchor or either end isn't currently visible.
    func extend(to url: URL, visibleOrder: [URL]) {
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

    /// Clear all multi-selection — clicking the empty sidebar background
    /// or switching workspace does this.
    func clear() {
        selection.removeAll()
        anchorURL = nil
    }

    // MARK: - Clipboard

    /// Mark the current selection for a Cut.  Items render at 50%
    /// opacity until pasted or replaced by another clipboard op.
    func cutSelection() {
        guard !selection.isEmpty else { return }
        clipboard = SidebarClipboard(urls: Array(selection), op: .cut)
        DebugLog.write("[sidebar] cut \(selection.count) items")
    }

    /// Mark the current selection for a Copy.
    func copySelection() {
        guard !selection.isEmpty else { return }
        clipboard = SidebarClipboard(urls: Array(selection), op: .copy)
        DebugLog.write("[sidebar] copy \(selection.count) items")
    }

    // MARK: - URL-keyed maintenance (driven by file operations)

    /// Update every URL-keyed piece of state when a path on disk moves
    /// from `old` to `new`.  Called by rename/move/paste.
    func translate(from old: URL, to new: URL) {
        let oldStd = old.standardizedFileURL
        let newStd = new.standardizedFileURL
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
        if expanded.contains(oldStd) {
            expanded.remove(oldStd)
            expanded.insert(newStd)
        }
    }

    /// Drop a URL that no longer exists on disk (trashed).  `url` must be
    /// standardised by the caller.
    func remove(_ url: URL) {
        selection.remove(url)
        if anchorURL?.standardizedFileURL == url { anchorURL = nil }
        if var clip = clipboard {
            clip.urls.removeAll { $0.standardizedFileURL == url }
            clipboard = clip.urls.isEmpty ? nil : clip
        }
        expanded.remove(url)
    }
}
