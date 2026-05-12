import Foundation

/// Persists a small list of recently opened markdown files in UserDefaults.
@MainActor
final class RecentFiles {
    static let shared = RecentFiles()

    private let key = "RecentFileURLs"
    private let maxCount = 10

    private init() {}

    var urls: [URL] {
        guard let raw = UserDefaults.standard.array(forKey: key) as? [String] else {
            return []
        }
        return raw.compactMap { URL(string: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    func push(_ url: URL) {
        var current = urls.filter { $0 != url }
        current.insert(url, at: 0)
        if current.count > maxCount { current = Array(current.prefix(maxCount)) }
        UserDefaults.standard.set(current.map { $0.absoluteString }, forKey: key)
    }

    func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}
