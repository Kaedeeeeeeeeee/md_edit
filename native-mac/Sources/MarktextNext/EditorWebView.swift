import SwiftUI
import WebKit

struct EditorWebView: NSViewRepresentable {
    @Environment(DocumentStore.self) private var store

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.add(context.coordinator, name: "editor")
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")

        // Serve the bundled editor over a custom scheme so module scripts +
        // crossorigin attrs (Vite default output) actually load.  file:// would
        // trip CORS on the very first <script type="module">.
        let schemeHandler = EditorSchemeHandler()
        config.setURLSchemeHandler(schemeHandler, forURLScheme: EditorSchemeHandler.scheme)
        context.coordinator.schemeHandler = schemeHandler
        context.coordinator.store = store
        context.coordinator.refreshAccessGrants()

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")

        context.coordinator.webView = webView

        let hasIndex = Bundle.main.url(
            forResource: "index",
            withExtension: "html",
            subdirectory: "editor"
        ) != nil
        if hasIndex {
            webView.load(URLRequest(url: EditorSchemeHandler.homeURL))
        } else {
            webView.loadHTMLString(missingBundleHTML, baseURL: nil)
        }
        return webView
    }

    // Pull pattern: SwiftUI re-invokes this whenever any observed property
    // on `store` changes.  Reading `store.loadEpoch` here registers it as a
    // dependency; the coordinator then compares against the last dispatched
    // epoch and only pushes to JS when a fresh load is required (file open,
    // new document, file delete).  Editor-originated changes don't bump the
    // epoch so we don't loop.
    func updateNSView(_ nsView: WKWebView, context: Context) {
        context.coordinator.store = store
        // Set grants BEFORE bumping the load epoch — if the editor re-renders
        // and immediately fetches an attachments/foo.png reference, the
        // grants must already be in place or we'd flash a broken image.
        context.coordinator.refreshAccessGrants()
        let epoch = store.loadEpoch
        let markdown = store.currentMarkdown
        context.coordinator.syncIfNeeded(epoch: epoch, markdown: markdown)
    }

    @MainActor
    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        weak var webView: WKWebView?
        weak var store: DocumentStore?
        /// WKWebViewConfiguration does NOT retain its scheme handlers, so we
        /// keep one alive here for the lifetime of the coordinator.
        var schemeHandler: EditorSchemeHandler?
        private var isReady = false
        private var lastDispatchedEpoch: Int = -1
        private var pending: (epoch: Int, markdown: String)?

        func syncIfNeeded(epoch: Int, markdown: String) {
            guard epoch != lastDispatchedEpoch else { return }
            lastDispatchedEpoch = epoch
            if isReady {
                sendLoad(markdown)
            } else {
                pending = (epoch, markdown)
            }
        }

        // MARK: - WKScriptMessageHandler

        nonisolated func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            Task { @MainActor in
                let body = message.body
                self.handleMessage(body)
            }
        }

        private func handleMessage(_ body: Any) {
            guard let dict = body as? [String: Any], let type = dict["type"] as? String else {
                return
            }
            switch type {
            case "ready":
                isReady = true
                if let pending {
                    self.pending = nil
                    sendLoad(pending.markdown)
                } else if let store {
                    // Editor ready but no explicit load has been requested
                    // yet (epoch 0).  Push the initial document anyway so
                    // the editor reflects whatever is in the store.
                    lastDispatchedEpoch = store.loadEpoch
                    sendLoad(store.currentMarkdown)
                }
            case "change":
                if let markdown = dict["markdown"] as? String {
                    store?.handleEditorChange(markdown)
                }
            case "saveImage":
                guard
                    let requestId = dict["requestId"] as? String,
                    let base64 = dict["base64"] as? String
                else { return }
                let ext = (dict["ext"] as? String) ?? "png"
                handleSaveImage(requestId: requestId, base64: base64, ext: ext)
            default:
                break
            }
        }

        private func handleSaveImage(requestId: String, base64: String, ext: String) {
            guard let store, let schemeHandler else {
                rejectUpload(requestId: requestId, message: "Editor not ready.")
                return
            }
            let stripped = base64.filter { !$0.isWhitespace && !$0.isNewline }
            guard let data = Data(base64Encoded: stripped) else {
                rejectUpload(requestId: requestId, message: "Image data was malformed.")
                return
            }

            // Try to resolve the image scope from already-known sources
            // (active workspace, or a previously-granted parent directory).
            if let scope = store.imageScope(for: store.currentFileURL) {
                writeImage(data: data, ext: ext, in: scope, requestId: requestId, store: store)
                return
            }

            // No scope yet.  If we have a file URL (floating doc), prompt the
            // user once for parent-dir authorization.  The granted URL is
            // pushed onto scheme handler grants so the new image (and any
            // existing image refs in the same doc) can be read back.
            if let fileURL = store.currentFileURL {
                DebugLog.write("[paste] requesting docDir grant for \(fileURL.lastPathComponent)")
                guard let docDir = DocumentDirBookmarks.requestGrant(for: fileURL) else {
                    rejectUpload(
                        requestId: requestId,
                        message: "Image not pasted — no folder authorised."
                    )
                    return
                }
                if !schemeHandler.accessGrants.contains(where: { $0.url == docDir }) {
                    schemeHandler.accessGrants.append(.init(url: docDir, role: .docDir))
                }
                writeImage(data: data, ext: ext, in: docDir, requestId: requestId, store: store)
                return
            }

            // Untitled with no workspace — post-phase-2 this shouldn't happen,
            // but handle gracefully.
            rejectUpload(
                requestId: requestId,
                message: "Save the document first so Marktext knows where to store images."
            )
        }

        private func writeImage(data: Data, ext: String, in scope: URL, requestId: String, store: DocumentStore) {
            do {
                let relativePath = try store.saveImageToAttachments(data: data, ext: ext, in: scope)
                resolveUpload(requestId: requestId, url: relativePath)
            } catch {
                rejectUpload(requestId: requestId, message: error.localizedDescription)
            }
        }

        /// Recompute the scheme handler's allowed read roots based on
        /// `store.folderURL` and the current document's parent-dir grant.
        /// Called from `updateNSView` (every store change) and from
        /// `makeNSView` (initial setup).
        func refreshAccessGrants() {
            guard let store, let schemeHandler else { return }
            var grants: [EditorSchemeHandler.AccessGrant] = []
            if let folder = store.folderURL {
                grants.append(.init(url: folder, role: .workspace))
            }
            // Floating doc?  Look up its parent-dir grant if one already
            // exists (don't prompt — that only happens on user paste).
            if let fileURL = store.currentFileURL,
               let folder = store.folderURL,
               !DocumentStore.contains(parent: folder, child: fileURL),
               let docDir = DocumentDirBookmarks.grant(for: fileURL) {
                grants.append(.init(url: docDir, role: .docDir))
            } else if let fileURL = store.currentFileURL,
                      store.folderURL == nil,
                      let docDir = DocumentDirBookmarks.grant(for: fileURL) {
                grants.append(.init(url: docDir, role: .docDir))
            }
            schemeHandler.accessGrants = grants
        }

        private func resolveUpload(requestId: String, url: String) {
            let js = "if (window.editorBridge && window.editorBridge.resolveUpload) { "
                + "window.editorBridge.resolveUpload(\(jsString(requestId)), \(jsString(url))); }"
            webView?.evaluateJavaScript(js, completionHandler: nil)
        }

        private func rejectUpload(requestId: String, message: String) {
            let js = "if (window.editorBridge && window.editorBridge.rejectUpload) { "
                + "window.editorBridge.rejectUpload(\(jsString(requestId)), \(jsString(message))); }"
            webView?.evaluateJavaScript(js, completionHandler: nil)
        }

        /// JSON-encode a string for safe injection into evaluateJavaScript.
        /// Wraps in an array + strips brackets to reuse the same escaping
        /// rules used by `sendLoad`.
        private func jsString(_ s: String) -> String {
            guard
                let data = try? JSONSerialization.data(withJSONObject: [s], options: [.fragmentsAllowed]),
                let str = String(data: data, encoding: .utf8)
            else { return "\"\"" }
            return String(str.dropFirst().dropLast())
        }

        // MARK: - WKNavigationDelegate

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: any Error
        ) {
            let ns = error as NSError
            DebugLog.write("[nav] provisional FAILED: \(ns.domain)#\(ns.code) \(error.localizedDescription)")
        }

        func webView(
            _ webView: WKWebView,
            didFail navigation: WKNavigation!,
            withError error: any Error
        ) {
            let ns = error as NSError
            DebugLog.write("[nav] FAILED: \(ns.domain)#\(ns.code) \(error.localizedDescription)")
        }

        private func sendLoad(_ markdown: String) {
            guard let webView else { return }
            let encoded: String
            if let data = try? JSONSerialization.data(
                withJSONObject: [markdown],
                options: [.fragmentsAllowed]
            ),
               let str = String(data: data, encoding: .utf8) {
                encoded = String(str.dropFirst().dropLast()) // strip outer [...]
            } else {
                encoded = "\"\""
            }
            let js = "if (window.editorBridge) { window.editorBridge.loadMarkdown(\(encoded)); }"
            webView.evaluateJavaScript(js) { _, error in
                if let error {
                    print("evaluateJavaScript loadMarkdown failed:", error)
                }
            }
        }
    }
}

private let missingBundleHTML = """
<!doctype html>
<html><head><meta charset="utf-8"><style>
body { font: 14px -apple-system; padding: 40px; color: #1d1d1f; }
h1 { font-weight: 600; }
code { background: #f0f0f0; padding: 2px 6px; border-radius: 4px; }
</style></head><body>
<h1>Editor bundle missing</h1>
<p>The web editor was not found in the app bundle.</p>
<p>Run <code>pnpm build</code> in <code>native-mac/web</code> and copy the <code>dist/</code>
contents to <code>native-mac/Resources/editor/</code>, then rebuild the .app.</p>
</body></html>
"""
