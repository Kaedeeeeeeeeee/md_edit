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

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")

        context.coordinator.webView = webView
        context.coordinator.store = store

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
            default:
                break
            }
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
