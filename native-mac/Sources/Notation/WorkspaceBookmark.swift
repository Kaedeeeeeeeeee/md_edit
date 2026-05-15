import Foundation

/// Persists the currently-open workspace folder (and the user's recent
/// workspaces) across app launches under macOS sandbox.
///
/// Bookmark primitives live in `SecurityScopedBookmark`; this file is just a
/// UserDefaults-backed facade with the workspace-specific keying and
/// recents-list management.
enum WorkspaceBookmark {
    private static let currentKey = "workspaceFolderBookmark"
    private static let recentKey = "recentWorkspaceBookmarks"
    private static let timestampsKey = "recentWorkspaceTimestamps"
    private static let recentMaxCount = 12

    /// Save the user-picked folder so the next launch can restore access.
    static func save(_ url: URL) {
        do {
            let data = try SecurityScopedBookmark.makeBlob(url: url)
            UserDefaults.standard.set(data, forKey: currentKey)
            pushRecent(data)
            recordAccess(url)
        } catch {
            print("WorkspaceBookmark.save failed:", error)
        }
    }

    /// Last-opened timestamp for a workspace URL, if we've ever opened it.
    static func lastAccessed(for url: URL) -> Date? {
        guard let dict = UserDefaults.standard.dictionary(forKey: timestampsKey) as? [String: TimeInterval] else {
            return nil
        }
        return dict[url.absoluteString].map { Date(timeIntervalSince1970: $0) }
    }

    private static func recordAccess(_ url: URL) {
        var dict = (UserDefaults.standard.dictionary(forKey: timestampsKey) as? [String: TimeInterval]) ?? [:]
        dict[url.absoluteString] = Date().timeIntervalSince1970
        UserDefaults.standard.set(dict, forKey: timestampsKey)
    }

    /// Resolve the previously-saved bookmark to a usable URL, starting access.
    /// Returns nil if no bookmark, the bookmark is unresolvable, or the folder
    /// has been moved/deleted.
    static func restore() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: currentKey) else { return nil }
        return SecurityScopedBookmark.resolve(data)
    }

    /// All saved recent workspaces, freshest first, with stale entries pruned.
    static func recentWorkspaces() -> [(url: URL, displayName: String)] {
        guard let list = UserDefaults.standard.array(forKey: recentKey) as? [Data] else {
            return []
        }
        var resolved: [(URL, String)] = []
        var keep: [Data] = []
        for data in list {
            guard let url = SecurityScopedBookmark.peek(data) else { continue }
            resolved.append((url, url.lastPathComponent))
            keep.append(data)
        }
        if keep.count != list.count {
            UserDefaults.standard.set(keep, forKey: recentKey)
        }
        return resolved
    }

    /// Resolve and adopt a previously-recent workspace bookmark.
    static func adoptRecent(_ url: URL) -> URL? {
        guard let list = UserDefaults.standard.array(forKey: recentKey) as? [Data] else {
            return nil
        }
        for data in list {
            if let candidate = SecurityScopedBookmark.resolve(data), candidate.absoluteURL == url.absoluteURL {
                UserDefaults.standard.set(data, forKey: currentKey)
                recordAccess(candidate)
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

    // MARK: - Recents list management

    private static func pushRecent(_ data: Data) {
        var current: [Data] = (UserDefaults.standard.array(forKey: recentKey) as? [Data]) ?? []
        let incomingURL = SecurityScopedBookmark.peek(data)
        current.removeAll { existing in
            if existing == data { return true }
            if let i = incomingURL,
               let e = SecurityScopedBookmark.peek(existing),
               e.absoluteURL == i.absoluteURL {
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
