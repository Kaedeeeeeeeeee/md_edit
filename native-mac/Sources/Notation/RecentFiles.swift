import Foundation

/// Persists recently-opened file grants across app launches under macOS sandbox.
///
/// Why bookmark blobs and not paths: files opened from Finder / NSOpenPanel may
/// sit outside the active workspace.  A plain path can be displayed after
/// relaunch, but the sandbox may deny even `stat`, and reading the file will
/// fail.  Security-scoped bookmarks carry the user's grant forward with the
/// file identity rather than trusting a path string.
@MainActor
final class RecentFiles {
    static let shared = RecentFiles()

    struct Entry: Identifiable, Hashable {
        let url: URL
        var id: String { url.absoluteString }
        var displayName: String { url.lastPathComponent }
    }

    private let key = "RecentFileBookmarks"
    private let legacyKey = "RecentFileURLs"
    private let maxCount = 10

    private init() {
        UserDefaults.standard.removeObject(forKey: legacyKey)
    }

    /// Freshest first.  Rendering paths must not retain sandbox handles; callers
    /// that intend to read/write must opt into `beginAccess(matching:)`.
    var entries: [Entry] {
        let blobs = storedBlobs()
        var keep: [Data] = []
        var result: [Entry] = []

        for blob in blobs {
            guard let url = SecurityScopedBookmark.peek(blob) else { continue }
            keep.append(blob)
            result.append(Entry(url: url))
        }

        if keep.count != blobs.count {
            UserDefaults.standard.set(keep, forKey: key)
        }

        return result
    }

    var urls: [URL] {
        entries.map(\.url)
    }

    func push(_ url: URL) {
        let blob: Data
        do {
            blob = try SecurityScopedBookmark.makeBlob(url: url)
        } catch {
            DebugLog.write("[recents] bookmark failed for \(url.path): \(error.localizedDescription)")
            return
        }

        var current = storedBlobs()
        current.removeAll { existing in
            guard let existingURL = SecurityScopedBookmark.peek(existing) else { return false }
            return sameFile(existingURL, url)
        }

        current.insert(blob, at: 0)
        if current.count > maxCount {
            current = Array(current.prefix(maxCount))
        }
        UserDefaults.standard.set(current, forKey: key)
    }

    func beginAccess(matching url: URL) -> URL? {
        let blobs = storedBlobs()
        var keep: [Data] = []
        var match: Data?

        for blob in blobs {
            guard let peekedURL = SecurityScopedBookmark.peek(blob) else { continue }
            keep.append(blob)
            if match == nil, sameFile(peekedURL, url) {
                match = blob
            }
        }

        if keep.count != blobs.count {
            UserDefaults.standard.set(keep, forKey: key)
        }

        guard let match else { return nil }
        return SecurityScopedBookmark.resolve(match)
    }

    func clear() {
        UserDefaults.standard.removeObject(forKey: key)
        UserDefaults.standard.removeObject(forKey: legacyKey)
    }

    private func storedBlobs() -> [Data] {
        (UserDefaults.standard.array(forKey: key) as? [Data]) ?? []
    }

    private func sameFile(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.standardizedFileURL == rhs.standardizedFileURL
    }
}
