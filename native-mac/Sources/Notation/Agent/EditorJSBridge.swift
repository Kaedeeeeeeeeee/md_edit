import Foundation
import WebKit

/// Thin async wrapper around the three `evaluateJavaScript` calls the native
/// AI Assistant panel makes back into the WebView. The WebView itself remains
/// the home of the BlockNote editor, so these are the only points where Swift
/// needs to talk to JS — fetching the document as markdown for "include doc"
/// context, and dropping AI output at the cursor or over a selection.
///
/// JS-side counterparts live in `web/src/agent/editorBridge.ts`
/// (`installEditorAgentBridge`).
@MainActor
final class EditorJSBridge {
    /// Reset by `EditorWebView` whenever a fresh WKWebView is created. The
    /// reference is weak so the bridge never extends the view's lifetime.
    weak var webView: WKWebView?

    /// Reads the current document as markdown. Returns an empty string if the
    /// editor isn't reachable (no webView, JS not installed, eval error, or a
    /// non-string return). Callers should treat empty as "no context".
    func getDocumentMarkdown() async -> String {
        guard let webView else { return "" }
        let js = "(window.editorBridge && window.editorBridge.aiGetDocumentMarkdown) ? window.editorBridge.aiGetDocumentMarkdown() : ''"
        return await withCheckedContinuation { continuation in
            webView.evaluateJavaScript(js) { value, error in
                if let error {
                    let ns = error as NSError
                    DebugLog.write("[agent] aiGetDocumentMarkdown failed: \(ns.domain)#\(ns.code)")
                    continuation.resume(returning: "")
                    return
                }
                continuation.resume(returning: (value as? String) ?? "")
            }
        }
    }

    func insertMarkdownAtCursor(_ markdown: String) {
        callBridgeWithMarkdown(method: "aiInsertAtCursor", markdown: markdown)
    }

    func replaceSelection(with markdown: String) {
        callBridgeWithMarkdown(method: "aiReplaceSelection", markdown: markdown)
    }

    // MARK: - Internals

    private func callBridgeWithMarkdown(method: String, markdown: String) {
        guard let webView else { return }
        // JSON-encode the markdown via a single-element array so any quotes,
        // newlines, or backslashes survive interpolation as a JS string
        // literal — same trick the existing dispatchers in EditorWebView use.
        let encoded: String
        if let data = try? JSONSerialization.data(
            withJSONObject: [markdown],
            options: [.fragmentsAllowed]
        ),
           let str = String(data: data, encoding: .utf8) {
            encoded = String(str.dropFirst().dropLast())
        } else {
            DebugLog.write("[agent] failed to JSON-encode markdown for \(method)")
            return
        }
        let js = "if (window.editorBridge && window.editorBridge.\(method)) { window.editorBridge.\(method)(\(encoded)); }"
        webView.evaluateJavaScript(js) { _, error in
            if let error {
                let ns = error as NSError
                DebugLog.write("[agent] \(method) evaluateJavaScript failed: \(ns.domain)#\(ns.code)")
            }
        }
    }
}
