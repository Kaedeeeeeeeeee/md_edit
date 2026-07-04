import Foundation
import UniformTypeIdentifiers

/// Path/filesystem helpers shared by the document and workspace layers.
/// Extracted from the old `DocumentStore` so both `DocumentSession` and
/// the workspace file operations can use them without depending on each
/// other (B2 refactor, phase 1).
enum FilePaths {
    /// Standardised-path containment check.  Standardises first so
    /// `~/Foo/../Bar` reduces correctly, and gates on the trailing-slash
    /// boundary so `/Foo` doesn't match `/FooBar/x`.  Equal paths count
    /// as contained.
    static func contains(parent: URL, child: URL) -> Bool {
        let parentPath = parent.standardizedFileURL.path
        let childPath = child.standardizedFileURL.path
        if parentPath == childPath { return true }
        let needle = parentPath.hasSuffix("/") ? parentPath : parentPath + "/"
        return childPath.hasPrefix(needle)
    }

    /// Collision-avoiding URL: returns `dir/name` if free, else appends
    /// `" 2"`, `" 3"`, ... preserving the extension.
    static func uniqueURL(in dir: URL, name: String) -> URL {
        let base = dir.appendingPathComponent(name)
        if !FileManager.default.fileExists(atPath: base.path) { return base }
        let stem = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        for i in 2...999 {
            let candidate = dir.appendingPathComponent(
                ext.isEmpty ? "\(stem) \(i)" : "\(stem) \(i).\(ext)"
            )
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return base
    }

    /// Extensions we treat as Markdown in the file tree and open panels.
    static func isMarkdown(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ["md", "markdown", "mdown", "mkd"].contains(ext)
    }

    /// Allowed content types for markdown open panels.
    static func markdownContentTypes() -> [UTType] {
        var types: [UTType] = [.plainText]
        if let md = UTType(filenameExtension: "md") { types.append(md) }
        if let mk = UTType(filenameExtension: "markdown") { types.append(mk) }
        return types
    }
}
