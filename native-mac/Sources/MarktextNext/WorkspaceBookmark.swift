import Foundation

/// Persists the currently-open workspace folder across app launches under
/// macOS sandbox by saving a security-scoped bookmark.
///
/// Without this, every relaunch loses the chosen folder because the sandbox
/// only grants access for the duration of the original NSOpenPanel choice.
///
/// Apple's pattern:
///  1. After the user picks a URL, call `url.bookmarkData(options: .withSecurityScope, ...)`
///     and persist the returned blob.
///  2. On launch, call `URL(resolvingBookmarkData:options:relativeTo:bookmarkDataIsStale:)`
///     with the same `.withSecurityScope` option to get a usable URL back.
///  3. Wrap usage in `startAccessingSecurityScopedResource()` / `stop…()`.
///     We start once when adopting the URL and rely on process exit to stop
///     (the kernel reclaims resources on quit).
enum WorkspaceBookmark {
    private static let currentKey = "workspaceFolderBookmark"
    private static let recentKey = "recentWorkspaceBookmarks"
    private static let recentMaxCount = 8

    /// Save the user-picked folder so the next launch can restore access.
    static func save(_ url: URL) {
        do {
            let data = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            UserDefaults.standard.set(data, forKey: currentKey)
            pushRecent(data)
        } catch {
            print("WorkspaceBookmark.save failed:", error)
        }
    }

    /// Resolve the previously-saved bookmark to a usable URL, starting access.
    /// Returns nil if no bookmark, the bookmark is unresolvable, or the folder
    /// has been moved/deleted.
    static func restore() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: currentKey) else { return nil }
        return resolve(data)
    }

    /// All saved recent workspaces, freshest first, with stale entries pruned.
    static func recentWorkspaces() -> [(url: URL, displayName: String)] {
        guard let list = UserDefaults.standard.array(forKey: recentKey) as? [Data] else {
            return []
        }
        var resolved: [(URL, String)] = []
        var keep: [Data] = []
        for data in list {
            guard let url = peek(data) else { continue }
            resolved.append((url, url.lastPathComponent))
            keep.append(data)
        }
        // Repersist any pruning.
        if keep.count != list.count {
            UserDefaults.standard.set(keep, forKey: recentKey)
        }
        return resolved
    }

    /// Resolve and adopt a previously-recent workspace bookmark.
    static func adoptRecent(_ url: URL) -> URL? {
        // Match by absoluteURL across the recent list.
        guard let list = UserDefaults.standard.array(forKey: recentKey) as? [Data] else {
            return nil
        }
        for data in list {
            if let candidate = resolve(data), candidate.absoluteURL == url.absoluteURL {
                UserDefaults.standard.set(data, forKey: currentKey)
                return candidate
            }
        }
        return nil
    }

    static func clearCurrent() {
        UserDefaults.standard.removeObject(forKey: currentKey)
    }

    static func clearRecent() {
        UserDefaults.standard.removeObject(forKey: recentKey)
    }

    // MARK: - Internals

    /// Resolve a bookmark blob and START accessing the security-scoped resource.
    private static func resolve(_ data: Data) -> URL? {
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
            print("WorkspaceBookmark.resolve failed:", error)
            return nil
        }
    }

    /// Resolve just for inspection (does NOT keep the security-scoped handle).
    private static func peek(_ data: Data) -> URL? {
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
                if !FileManager.default.fileExists(atPath: url.path) {
                    return nil
                }
            }
            return url
        } catch {
            return nil
        }
    }

    private static func pushRecent(_ data: Data) {
        var current: [Data] = (UserDefaults.standard.array(forKey: recentKey) as? [Data]) ?? []
        // De-dupe by bookmark blob equality, then by resolved path
        let incomingURL = peek(data)
        current.removeAll { existing in
            if existing == data { return true }
            if let i = incomingURL, let e = peek(existing), e.absoluteURL == i.absoluteURL {
                return true
            }
            return false
        }
        current.insert(data, at: 0)
        if current.count > recentMaxCount {
            current = Array(current.prefix(recentMaxCount))
        }
        UserDefaults.standard.set(current, forKey: recentKey)
    }
}
