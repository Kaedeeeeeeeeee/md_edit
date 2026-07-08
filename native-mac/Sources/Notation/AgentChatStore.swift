import Foundation
import CryptoKit

/// Per-document chat history persistence. Stores one JSON file per .md file
/// path under the app's sandboxed Application Support directory.
///
/// File location: <sandbox>/Library/Application Support/Notation/agent-chats/<sha1>.json
/// SHA-1 (not SHA-256) is fine here — collision space is far larger than the
/// number of files a single user can have. Privacy: full file path is NEVER
/// written; only its hash and the basename for human debugging.
enum AgentChatStore {

    struct PersistedMessage: Codable {
        var id: String
        var role: String
        var content: String
    }

    private struct ChatFile: Codable {
        var version: Int
        var pathHash: String
        var documentTitle: String
        var savedAt: String
        var messages: [PersistedMessage]
    }

    private static let dirPath: String = {
        let appSupport = NSHomeDirectory() + "/Library/Application Support/Notation/agent-chats"
        try? FileManager.default.createDirectory(atPath: appSupport, withIntermediateDirectories: true)
        return appSupport
    }()

    private static func fileURL(for fileURL: URL) -> URL {
        let hash = sha1(fileURL.path)
        return URL(fileURLWithPath: dirPath).appendingPathComponent("\(hash).json")
    }

    static func load(for documentURL: URL?) -> [PersistedMessage] {
        guard let documentURL else { return [] }
        let url = fileURL(for: documentURL)
        guard let data = try? Data(contentsOf: url) else { return [] }
        guard let file = try? JSONDecoder().decode(ChatFile.self, from: data) else { return [] }
        return file.messages
    }

    static func save(_ messages: [PersistedMessage], for documentURL: URL?) {
        guard let documentURL else { return }   // unsaved docs don't persist
        let url = fileURL(for: documentURL)
        let payload = ChatFile(
            version: 1,
            pathHash: sha1(documentURL.path),
            documentTitle: documentURL.lastPathComponent,
            savedAt: ISO8601DateFormatter().string(from: Date()),
            messages: messages
        )
        guard let data = try? JSONEncoder().encode(payload) else { return }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            let ns = error as NSError
            DebugLog.write("[agent-chat] save failed for \(documentURL.lastPathComponent): \(ns.domain)#\(ns.code)")
        }
    }

    static func clear(for documentURL: URL?) {
        guard let documentURL else { return }
        let url = fileURL(for: documentURL)
        try? FileManager.default.removeItem(at: url)
    }

    private static func sha1(_ s: String) -> String {
        let data = Data(s.utf8)
        let hash = Insecure.SHA1.hash(data: data)
        return hash.map { String(format: "%02x", $0) }.joined()
    }
}
