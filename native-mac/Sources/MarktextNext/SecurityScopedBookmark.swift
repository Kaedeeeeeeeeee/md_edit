import Foundation

/// Primitive operations on macOS sandbox security-scoped bookmark blobs.
///
/// Owns the `bookmarkData(options:.withSecurityScope, ...)` /
/// `URL(resolvingBookmarkData:options:.withSecurityScope, ...)` pair, plus
/// the start-access dance.  Higher-level stores (current workspace, recent
/// workspaces, per-doc-dir grants) compose these primitives onto their own
/// UserDefaults keying.
///
/// Why bookmark blobs and not paths: bookmarks encode file-identity (inode +
/// volume UUID), so they survive renames and moves.  Path-keyed caches go
/// stale the moment the user touches Finder.
enum SecurityScopedBookmark {
    /// Serialise a URL into a security-scoped bookmark blob suitable for
    /// persistence in UserDefaults / disk.
    static func makeBlob(url: URL) throws -> Data {
        try url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    /// Resolve a bookmark blob and **start** accessing the security-scoped
    /// resource.  Caller is responsible for calling `url.stopAccessing…` when
    /// done, or relying on process exit to release.
    ///
    /// Returns nil if the bookmark is unresolvable (target moved/deleted, or
    /// the kernel refuses to start access).
    static func resolve(_ data: Data) -> URL? {
        var isStale = false
        do {
            let url = try URL(
                resolvingBookmarkData: data,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            guard url.startAccessingSecurityScopedResource() else { return nil }
            return url
        } catch {
            return nil
        }
    }

    /// Resolve a bookmark blob *just to look at the URL* — does NOT keep the
    /// security-scoped handle open.  Useful for menu/recent-list rendering
    /// where we never actually read or write the underlying file.
    static func peek(_ data: Data) -> URL? {
        var isStale = false
        do {
            let url = try URL(
                resolvingBookmarkData: data,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            if url.startAccessingSecurityScopedResource() {
                defer { url.stopAccessingSecurityScopedResource() }
                guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            }
            return url
        } catch {
            return nil
        }
    }
}
