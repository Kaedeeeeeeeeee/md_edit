import Foundation
import WebKit
import UniformTypeIdentifiers

/// Serves the embedded React editor (under `Contents/Resources/editor/`)
/// over a custom URL scheme so WKWebView treats it as a normal HTTP-style
/// origin.
///
/// Why this exists: loading the editor via `file://` triggers WebKit's strict
/// CORS rules whenever the index.html contains `<script type="module" crossorigin>`
/// — which Vite emits by default.  Module subresources end up with a null
/// origin and CORS denies them; React never mounts and the editor stays
/// blank.  A custom scheme avoids the file:// problem entirely *and* uses
/// only public WebKit API, so the app is App Store-eligible.
@MainActor
final class EditorSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "marktext-editor"
    static let homeURL = URL(string: "\(scheme)://app/index.html")!

    /// A directory the editor is allowed to serve files from in addition to
    /// the bundled editor.  Roles distinguish workspace (one) from
    /// per-document grants (any number) so logging is meaningful.
    struct AccessGrant: Equatable {
        enum Role: String { case workspace, docDir }
        let url: URL
        let role: Role
    }

    /// Read roots in priority order: bundle is implicit grant[-1] (always
    /// tried first).  Each entry is checked next; first hit wins.  Set by
    /// `EditorWebView.updateNSView` whenever the active workspace or the
    /// current document's parent-dir grant changes.
    var accessGrants: [AccessGrant] = []

    /// Directory of the document currently shown in the editor.  Markdown
    /// image references like `style-check.png` are relative to *this*
    /// directory — not the editor's `marktext-editor://app/` page root, which
    /// is where WebKit resolves them before handing them to us.  Resolved
    /// against here first (see `loadDocumentRelative`).  Set by
    /// `EditorWebView.updateNSView` alongside `accessGrants`.
    var documentDirectory: URL?

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url else {
            DebugLog.write("[scheme] no URL on task")
            fail(urlSchemeTask, code: NSURLErrorBadURL)
            return
        }

        // Path inside our editor bundle subdirectory.  The URL is something
        // like `marktext-editor://app/assets/foo.js` — we want `assets/foo.js`.
        var relative = url.path
        if relative.hasPrefix("/") { relative.removeFirst() }
        if relative.isEmpty { relative = "index.html" }

        // Try the bundled editor first.  Falling back to authorised roots
        // lets user markdown reference attachments by relative path
        // (`attachments/foo.png`) — workspace and per-document grants both
        // honour the same containment check, so a markdown reference can't
        // escape its scope into arbitrary disk locations.
        if let data = loadFromBundle(relative: relative) {
            respond(urlSchemeTask, url: url, data: data)
            return
        }

        // Document-relative resolution.  WebKit resolved a markdown reference
        // like `style-check.png` against the page root (`marktext-editor://
        // app/`), losing the fact that it's relative to the *document's*
        // directory.  Re-resolve against that directory so a sibling image
        // next to the `.md` (or `images/foo.png` in a subfolder) loads — even
        // when the document lives in a workspace subdirectory.  The read is
        // gated on containment within an authorised root, so a `..`-laden
        // reference can't escape the workspace / granted directory.
        if let docDir = documentDirectory,
           let data = loadDocumentRelative(relative: relative, docDir: docDir) {
            respond(urlSchemeTask, url: url, data: data)
            return
        }

        for grant in accessGrants {
            if let data = loadFromGrant(grant, relative: relative) {
                respond(urlSchemeTask, url: url, data: data)
                return
            }
        }

        DebugLog.write("[scheme] not found: \(relative)")
        fail(urlSchemeTask, code: NSURLErrorFileDoesNotExist)
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
        // Synchronous handler — nothing to cancel.
    }

    private func loadFromBundle(relative: String) -> Data? {
        guard let resourcePath = Bundle.main.resourcePath else { return nil }
        let editorRoot = URL(fileURLWithPath: resourcePath)
            .appendingPathComponent("editor", isDirectory: true)
            .standardizedFileURL
        let candidate = editorRoot.appendingPathComponent(relative).standardizedFileURL
        guard isContained(candidate: candidate, in: editorRoot) else { return nil }
        return try? Data(contentsOf: candidate)
    }

    private func loadFromGrant(_ grant: AccessGrant, relative: String) -> Data? {
        let root = grant.url.standardizedFileURL
        let candidate = root.appendingPathComponent(relative).standardizedFileURL
        guard isContained(candidate: candidate, in: root) else { return nil }
        return try? Data(contentsOf: candidate)
    }

    /// Resolve `relative` against the open document's directory.  Only returns
    /// data when the resolved file stays inside one of `accessGrants`: the
    /// document directory is itself either a workspace subdirectory (covered
    /// by the workspace grant) or a per-document bookmark grant, so that
    /// containment check doubles as the read-permission gate.  Without a
    /// covering grant we return nil and the caller falls through to a
    /// `not found` — which is what surfaces the "Allow Access" banner.
    private func loadDocumentRelative(relative: String, docDir: URL) -> Data? {
        let candidate = docDir.appendingPathComponent(relative).standardizedFileURL
        let authorised = accessGrants.contains {
            isContained(candidate: candidate, in: $0.url.standardizedFileURL)
        }
        guard authorised else { return nil }
        return try? Data(contentsOf: candidate)
    }

    /// Standardised-path containment check that rejects `..` escapes and
    /// "sibling with same prefix" false positives (e.g. `/foo/editor` vs
    /// `/foo/editor.bak/x`).
    private func isContained(candidate: URL, in root: URL) -> Bool {
        let rootPath = root.path
        let candidatePath = candidate.path
        if candidatePath == rootPath { return true }
        let needle = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        return candidatePath.hasPrefix(needle)
    }

    private func respond(_ task: any WKURLSchemeTask, url: URL, data: Data) {
        let mime = mimeType(for: url)
        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: [
                "Content-Type": mime,
                "Content-Length": String(data.count),
                "Cache-Control": "no-store"
            ]
        ) ?? URLResponse(
            url: url,
            mimeType: mime,
            expectedContentLength: data.count,
            textEncodingName: nil
        )
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    // MARK: - Helpers

    private func fail(_ task: any WKURLSchemeTask, code: Int) {
        task.didFailWithError(NSError(domain: NSURLErrorDomain, code: code))
    }

    private func mimeType(for url: URL) -> String {
        // Prefer UTType-derived MIME, fall back to a small extension table for
        // the few cases UTType doesn't know about reliably across versions.
        if let type = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType {
            return type
        }
        switch url.pathExtension.lowercased() {
        case "html", "htm": return "text/html"
        case "js", "mjs": return "application/javascript"
        case "css": return "text/css"
        case "json": return "application/json"
        case "svg": return "image/svg+xml"
        case "woff": return "font/woff"
        case "woff2": return "font/woff2"
        case "ttf": return "font/ttf"
        case "otf": return "font/otf"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        default: return "application/octet-stream"
        }
    }
}
