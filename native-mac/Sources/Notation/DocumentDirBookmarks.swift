import Foundation
import AppKit

/// Per-document-directory security-scoped bookmark cache.
///
/// Used by image paste for documents that live outside the active workspace
/// (e.g., the user double-clicked `~/Desktop/random.md` from Finder).  The
/// sandbox grants only the file URL itself in that case — to write a new
/// image into `~/Desktop/attachments/` we need a separate authorization
/// for the parent directory.  This store handles that.
///
/// Lookups walk the stored bookmarks rather than keying by path, so:
///   1. Renames/moves of the granted dir don't invalidate (bookmarks track
///      file-identity via inode + volume UUID).
///   2. A grant for `~/Documents` automatically covers `~/Documents/Sub/foo.md`
///      without re-prompting (nested reuse falls out for free).
@MainActor
enum DocumentDirBookmarks {
    private static let storageKey = "docDirBookmarks"

    /// Find a grant whose URL contains `fileURL`.  Returns a started,
    /// security-scoped URL — the caller must NOT call
    /// `stopAccessingSecurityScopedResource()` until the resource is no
    /// longer needed (we leave it open for the lifetime of subsequent
    /// reads/writes through `EditorSchemeHandler`).
    static func grant(for fileURL: URL) -> URL? {
        let blobs = storedBlobs()
        var kept: [Data] = []
        var match: URL?
        for blob in blobs {
            if let url = SecurityScopedBookmark.resolve(blob) {
                kept.append(blob)
                if match == nil, contains(parent: url, child: fileURL) {
                    match = url
                }
            }
            // Unresolvable blobs are dropped (purge stale).
        }
        if kept.count != blobs.count {
            UserDefaults.standard.set(kept, forKey: storageKey)
        }
        return match
    }

    /// Prompt the user for permission to read/write the file's parent
    /// directory.  Persists the resulting bookmark on success.  Returns
    /// the started, security-scoped URL on grant, or nil if the user
    /// cancelled.
    static func requestGrant(for fileURL: URL) -> URL? {
        let parent = fileURL.deletingLastPathComponent()
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = parent
        panel.prompt = "Use This Folder for Images"
        panel.message = "Choose where to save pasted images for “\(fileURL.lastPathComponent)”. " +
            "Notation will reuse this folder for other files in the same directory."
        guard panel.runModal() == .OK, let url = panel.url else {
            DebugLog.write("[grant] user cancelled for \(fileURL.lastPathComponent)")
            return nil
        }
        do {
            let blob = try SecurityScopedBookmark.makeBlob(url: url)
            var current = storedBlobs()
            // Drop any existing blob that resolves to the same URL.
            current.removeAll { existing in
                if existing == blob { return true }
                if let resolved = SecurityScopedBookmark.resolve(existing) {
                    return resolved.absoluteURL == url.absoluteURL
                }
                return false
            }
            current.insert(blob, at: 0)
            UserDefaults.standard.set(current, forKey: storageKey)
            DebugLog.write("[grant] saved for \(url.path)")
            return SecurityScopedBookmark.resolve(blob)
        } catch {
            DebugLog.write("[grant] bookmark failed: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Internals

    private static func storedBlobs() -> [Data] {
        (UserDefaults.standard.array(forKey: storageKey) as? [Data]) ?? []
    }

    /// True if `child` is contained inside `parent` after path
    /// standardisation.  Equal paths count as contained (parent==child case
    /// would mean opening a directory as a file — shouldn't happen, but
    /// safe).
    private static func contains(parent: URL, child: URL) -> Bool {
        let parentPath = parent.standardizedFileURL.path
        let childPath = child.standardizedFileURL.path
        if parentPath == childPath { return true }
        let needle = parentPath.hasSuffix("/") ? parentPath : parentPath + "/"
        return childPath.hasPrefix(needle)
    }
}
