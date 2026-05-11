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
final class EditorSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "marktext-editor"
    static let homeURL = URL(string: "\(scheme)://app/index.html")!

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url else {
            fail(urlSchemeTask, code: NSURLErrorBadURL)
            return
        }

        // Path inside our editor bundle subdirectory.  The URL is something
        // like `marktext-editor://app/assets/foo.js` — we want `assets/foo.js`.
        var relative = url.path
        if relative.hasPrefix("/") { relative.removeFirst() }
        if relative.isEmpty { relative = "index.html" }

        guard
            let resourcePath = Bundle.main.resourcePath
        else {
            fail(urlSchemeTask, code: NSURLErrorResourceUnavailable)
            return
        }

        let fileURL = URL(fileURLWithPath: resourcePath)
            .appendingPathComponent("editor", isDirectory: true)
            .appendingPathComponent(relative)

        // Confine reads to the editor subdirectory.  Standardising the path
        // resolves any `..` traversal attempts before the prefix check.
        let editorRoot = URL(fileURLWithPath: resourcePath)
            .appendingPathComponent("editor", isDirectory: true)
            .standardizedFileURL.path
        let resolved = fileURL.standardizedFileURL.path
        guard resolved.hasPrefix(editorRoot) else {
            fail(urlSchemeTask, code: NSURLErrorNoPermissionsToReadFile)
            return
        }

        guard let data = try? Data(contentsOf: fileURL) else {
            fail(urlSchemeTask, code: NSURLErrorFileDoesNotExist)
            return
        }

        let mime = mimeType(for: fileURL)
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

        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
        // Synchronous handler — nothing to cancel.
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
