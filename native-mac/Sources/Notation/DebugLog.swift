import Foundation

/// File-based debug logging that bypasses unified-log filtering.
/// Writes to `<sandbox container>/Documents/mt-debug.log`.
enum DebugLog {
    private static let lock = NSLock()
    private static let path: String = {
        // For sandboxed apps NSHomeDirectory() returns the container's Data
        // directory, which is writable.
        let documents = (NSHomeDirectory() as NSString).appendingPathComponent("Documents")
        try? FileManager.default.createDirectory(
            atPath: documents,
            withIntermediateDirectories: true
        )
        return (documents as NSString).appendingPathComponent("mt-debug.log")
    }()

    /// Mirror log lines to stdout when launched with NOTATION_STDOUT_LOG=1.
    /// The container log file is TCC-protected — running the binary
    /// directly from a terminal with this flag is the only way to watch
    /// the log live without granting Full Disk Access.
    private static let mirrorToStdout =
        ProcessInfo.processInfo.environment["NOTATION_STDOUT_LOG"] != nil
    private static let enableReleaseFileLog =
        ProcessInfo.processInfo.environment["NOTATION_RELEASE_LOG"] != nil

    static func write(_ message: String) {
        #if DEBUG
        let logMessage = message
        #else
        guard enableReleaseFileLog || mirrorToStdout else { return }
        let logMessage = redactSensitiveReleaseText(message)
        #endif

        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = "\(timestamp) \(logMessage)\n"
        guard let data = line.data(using: .utf8) else { return }
        lock.lock()
        defer { lock.unlock() }
        if mirrorToStdout {
            // FileHandle write, not print(): stdout redirected to a file is
            // fully buffered, and buffered lines never land if the app is
            // killed instead of exiting cleanly.
            FileHandle.standardOutput.write(data)
        }
        if FileManager.default.fileExists(atPath: path) {
            if let handle = try? FileHandle(forWritingTo: URL(fileURLWithPath: path)) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            }
        } else {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }

    static func reset() {
        try? FileManager.default.removeItem(atPath: path)
    }

    #if !DEBUG
    private static func redactSensitiveReleaseText(_ message: String) -> String {
        var redacted = message
        redacted = redacted.replacingOccurrences(of: NSHomeDirectory(), with: "<home>")
        if let regex = try? NSRegularExpression(pattern: #"/Users/[^\s,)"]+"#) {
            let range = NSRange(redacted.startIndex..., in: redacted)
            redacted = regex.stringByReplacingMatches(
                in: redacted,
                options: [],
                range: range,
                withTemplate: "<path>"
            )
        }
        return redacted
    }
    #endif
}
