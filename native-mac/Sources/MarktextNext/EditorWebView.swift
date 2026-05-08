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

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")

        context.coordinator.webView = webView
        context.coordinator.attach(store: store)

        if let htmlURL = Bundle.main.url(
            forResource: "index",
            withExtension: "html",
            subdirectory: "editor"
        ) {
            webView.loadFileURL(htmlURL, allowingReadAccessTo: htmlURL.deletingLastPathComponent())
        } else {
            webView.loadHTMLString(missingBundleHTML, baseURL: nil)
        }
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        context.coordinator.attach(store: store)
    }

    @MainActor
    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        weak var webView: WKWebView?
        weak var store: DocumentStore?
        private var isReady = false
        private var pendingMarkdown: String?

        func attach(store: DocumentStore) {
            self.store = store
            store.loadIntoEditor = { [weak self] markdown in
                guard let self else { return }
                if self.isReady {
                    self.sendLoad(markdown)
                } else {
                    self.pendingMarkdown = markdown
                }
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
                if let pending = pendingMarkdown {
                    pendingMarkdown = nil
                    sendLoad(pending)
                } else if let md = store?.currentMarkdown {
                    sendLoad(md)
                }
            case "change":
                if let markdown = dict["markdown"] as? String {
                    store?.handleEditorChange(markdown)
                }
            default:
                break
            }
        }

        private func sendLoad(_ markdown: String) {
            guard let webView else { return }
            let encoded: String
            if let data = try? JSONSerialization.data(
                withJSONObject: [markdown],
                options: [.fragmentsAllowed]
            ),
               let str = String(data: data, encoding: .utf8) {
                let trimmed = String(str.dropFirst().dropLast()) // strip the [...]
                encoded = trimmed
            } else {
                encoded = "\"\""
            }
            let js = "window.editorBridge && window.editorBridge.loadMarkdown(\(encoded));"
            webView.evaluateJavaScript(js, completionHandler: nil)
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
