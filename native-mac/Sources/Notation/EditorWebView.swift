import SwiftUI
import WebKit

struct EditorWebView: NSViewRepresentable {
    @Environment(DocumentStore.self) private var store
    @Environment(AgentChatController.self) private var agentChat

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.add(context.coordinator, name: "editor")

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
        webView.underPageBackgroundColor = .clear
        #if DEBUG
        webView.isInspectable = true
        #endif

        context.coordinator.webView = webView
        // Hand the same WKWebView to the agent's JS bridge so the chat panel
        // (native SwiftUI) can call into the WebView for editor operations
        // (insert/replace/get-doc-markdown).
        agentChat.bridge.webView = webView
        context.coordinator.registerPageActionObserver()
        context.coordinator.registerResearchObserver()

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
    // on `store` changes.  Reading `store.document.loadEpoch` here registers it as a
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
        let epoch = store.document.loadEpoch
        let markdown = store.document.currentMarkdown
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
        // Active streaming AI tasks, keyed by JS-supplied requestId. Looked up
        // from `handleMessage(... "ai-abort")` so the JS side can stop a run.
        // Main-actor isolated — only touched from `handleMessage` (already on
        // the main actor) and from the completion callback (which also hops
        // via `MainActor.run`).
        private var activeAITasks: [String: Task<Void, Never>] = [:]
        // `nonisolated(unsafe)` so the implicit-nonisolated `deinit` can read
        // it to unregister the observer. The token is only mutated from the
        // main actor (in `registerPageActionObserver`) and only read at
        // deinit, so racing is not a concern in practice.
        nonisolated(unsafe) private var pageActionObserver: NSObjectProtocol?
        nonisolated(unsafe) private var researchObserver: NSObjectProtocol?

        func registerPageActionObserver() {
            pageActionObserver = NotificationCenter.default.addObserver(
                forName: .aiPageActionRequested,
                object: nil,
                queue: .main
            ) { [weak self] note in
                guard let self,
                      let action = note.userInfo?["action"] as? String else { return }
                Task { @MainActor in
                    self.dispatchPageAction(action)
                }
            }
        }

        func registerResearchObserver() {
            researchObserver = NotificationCenter.default.addObserver(
                forName: .aiResearchRequested,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                guard let self else { return }
                Task { @MainActor in
                    self.dispatchResearchOpen()
                }
            }
        }

        private func dispatchResearchOpen() {
            guard let webView else { return }
            let js = "if (window.editorBridge?.openResearch) { window.editorBridge.openResearch(); }"
            webView.evaluateJavaScript(js) { _, error in
                if let error {
                    DebugLog.write("[research] openResearch evaluateJavaScript failed: \(error)")
                }
            }
        }

        private func dispatchPageAction(_ action: String) {
            guard let webView else { return }
            let encoded: String
            if let data = try? JSONSerialization.data(
                withJSONObject: [action],
                options: [.fragmentsAllowed]
            ),
               let str = String(data: data, encoding: .utf8) {
                encoded = String(str.dropFirst().dropLast())
            } else {
                encoded = "\"summarize\""
            }
            let js = "if (window.editorBridge?.runPageAction) { window.editorBridge.runPageAction(\(encoded)); }"
            webView.evaluateJavaScript(js) { _, error in
                if let error {
                    DebugLog.write("[ai] runPageAction evaluateJavaScript failed: \(error)")
                }
            }
        }

        deinit {
            if let pageActionObserver {
                NotificationCenter.default.removeObserver(pageActionObserver)
            }
            if let researchObserver {
                NotificationCenter.default.removeObserver(researchObserver)
            }
        }

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
                // Push locale first so the editor remounts under the right
                // dictionary before content arrives — avoids a momentary
                // English slash menu when launching under zh-Hans.
                sendSetLocale(currentLocaleCode())
                if let pending {
                    self.pending = nil
                    sendLoad(pending.markdown)
                } else if let store {
                    // Editor ready but no explicit load has been requested
                    // yet (epoch 0).  Push the initial document anyway so
                    // the editor reflects whatever is in the store.
                    lastDispatchedEpoch = store.document.loadEpoch
                    sendLoad(store.document.currentMarkdown)
                }
            case "change":
                if let markdown = dict["markdown"] as? String {
                    store?.document.handleEditorChange(markdown)
                }
            case "saveImage":
                guard
                    let requestId = dict["requestId"] as? String,
                    let base64 = dict["base64"] as? String
                else { return }
                let ext = (dict["ext"] as? String) ?? "png"
                handleSaveImage(requestId: requestId, base64: base64, ext: ext)
            case "ai-request":
                handleAIRequest(dict)
            case "ai-abort":
                handleAIAbort(dict)
            case "ai-image-request":
                handleImageRequest(dict)
            case "ai-research-request":
                handleResearchRequest(dict)
            case "ai-provider-probe":
                handleProviderProbe(dict)
            case "open-settings":
                openSettings()
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
            if let scope = store.document.imageScope(for: store.document.currentFileURL) {
                writeImage(data: data, ext: ext, in: scope, requestId: requestId, store: store)
                return
            }

            // No scope yet.  If we have a file URL (floating doc), prompt the
            // user once for parent-dir authorization.  The granted URL is
            // pushed onto scheme handler grants so the new image (and any
            // existing image refs in the same doc) can be read back.
            if let fileURL = store.document.currentFileURL {
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
                message: "Save the document first so Notation knows where to store images."
            )
        }

        private func writeImage(data: Data, ext: String, in scope: URL, requestId: String, store: DocumentStore) {
            do {
                let relativePath = try store.workspace.saveImageToAttachments(data: data, ext: ext, in: scope)
                resolveUpload(requestId: requestId, url: relativePath)
            } catch {
                rejectUpload(requestId: requestId, message: error.localizedDescription)
            }
        }

        /// Recompute the scheme handler's allowed read roots based on
        /// `store.workspace.folderURL` and the current document's parent-dir grant.
        /// Called from `updateNSView` (every store change) and from
        /// `makeNSView` (initial setup).
        func refreshAccessGrants() {
            guard let store, let schemeHandler else { return }
            var grants: [EditorSchemeHandler.AccessGrant] = []
            if let folder = store.workspace.folderURL {
                grants.append(.init(url: folder, role: .workspace))
            }
            // Floating doc?  Look up its parent-dir grant if one already
            // exists (don't prompt — that only happens on user paste).
            if let fileURL = store.document.currentFileURL,
               let folder = store.workspace.folderURL,
               !FilePaths.contains(parent: folder, child: fileURL),
               let docDir = DocumentDirBookmarks.grant(for: fileURL) {
                grants.append(.init(url: docDir, role: .docDir))
            } else if let fileURL = store.document.currentFileURL,
                      store.workspace.folderURL == nil,
                      let docDir = DocumentDirBookmarks.grant(for: fileURL) {
                grants.append(.init(url: docDir, role: .docDir))
            }
            schemeHandler.accessGrants = grants
            // Resolution base for the open document's relative image refs.
            // The directory is only *readable* when it's inside one of the
            // grants above; the scheme handler enforces that containment.
            schemeHandler.documentDirectory = store.document.currentFileURL?
                .deletingLastPathComponent()
                .standardizedFileURL
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

        private func handleAIRequest(_ dict: [String: Any]) {
            guard let requestId = dict["requestId"] as? String else {
                DebugLog.write("[ai] malformed request — missing requestId")
                return
            }
            let messagesRaw = dict["messages"] as? [[String: Any]]
            let messages: [(role: String, content: String)]? = messagesRaw.map { array in
                array.compactMap { item -> (role: String, content: String)? in
                    guard let r = item["role"] as? String, let c = item["content"] as? String else { return nil }
                    return (role: r, content: c)
                }
            }
            // Multi-turn calls don't require `prompt`; single-shot calls do.
            let prompt = (dict["prompt"] as? String) ?? ""
            if (messages?.isEmpty ?? true) && prompt.isEmpty {
                DebugLog.write("[ai] malformed request — missing prompt and messages")
                return
            }
            let selected = (dict["selectedMarkdown"] as? String) ?? ""
            let before = (dict["contextBefore"] as? String) ?? ""
            let after = (dict["contextAfter"] as? String) ?? ""

            // Pro gating: AI features require an unlocked entitlement.
            // Send a structured error back through the existing stream-end
            // channel so the floating AI popup closes gracefully, and post
            // the paywall request so the main scene's sheet listener pops
            // the upgrade UI.
            guard EntitlementState.shared.isPro else {
                DebugLog.write("[ai] request \(requestId) gated — not Pro")
                NotificationCenter.default.post(name: .proPaywallRequested, object: nil)
                sendAIStreamEnd(requestId: requestId, result: .failure(.proRequired))
                return
            }

            // If another request already used this id (shouldn't happen — UUIDs
            // — but defend anyway), cancel the previous one so the dictionary
            // never leaks a Task.
            activeAITasks[requestId]?.cancel()

            let task = Task { @MainActor [weak self] in
                await AIService.shared.runStreamingRequest(
                    userPrompt: prompt,
                    selectedMarkdown: selected,
                    contextBefore: before,
                    contextAfter: after,
                    messages: messages,
                    onDelta: { [weak self] chunk in
                        self?.sendAIStreamChunk(requestId: requestId, delta: chunk)
                    },
                    onComplete: { [weak self] result in
                        self?.sendAIStreamEnd(requestId: requestId, result: result)
                        self?.activeAITasks.removeValue(forKey: requestId)
                    }
                )
            }
            activeAITasks[requestId] = task
        }

        private func handleAIAbort(_ dict: [String: Any]) {
            guard let requestId = dict["requestId"] as? String else {
                DebugLog.write("[ai] malformed abort — missing requestId")
                return
            }
            if let task = activeAITasks.removeValue(forKey: requestId) {
                DebugLog.write("[ai] aborting request \(requestId)")
                task.cancel()
            } else {
                DebugLog.write("[ai] abort for unknown requestId \(requestId)")
            }
        }

        // MARK: - AI image generation

        /// Handles `ai-image-request` messages from JS. Fires the OpenAI image
        /// API in a detached Task, then hops back to the main actor to push
        /// the result to JS via `aiImageResponse`.
        ///
        /// Unlike text generation we don't track this in `activeAITasks` —
        /// image generation is single-shot, fast enough not to need an abort,
        /// and the JS side just shows a spinner until it returns.
        private func handleImageRequest(_ dict: [String: Any]) {
            guard let requestId = dict["requestId"] as? String,
                  let prompt = dict["prompt"] as? String else {
                DebugLog.write("[ai] image request missing requestId/prompt")
                return
            }
            guard EntitlementState.shared.isPro else {
                DebugLog.write("[ai] image request \(requestId) gated — not Pro")
                NotificationCenter.default.post(name: .proPaywallRequested, object: nil)
                sendImageResponse(requestId: requestId, result: .failure(.proRequired))
                return
            }
            Task { [weak self] in
                let result = await AIService.shared.runImageGeneration(prompt: prompt)
                await MainActor.run {
                    self?.sendImageResponse(requestId: requestId, result: result)
                }
            }
        }

        // MARK: - AI provider probe

        /// Replies with the currently-configured provider and whether a key
        /// is set for it. Used by the research popup to gate the input form
        /// without firing a real request first. Cheap synchronous lookup
        /// against UserDefaults + Keychain.
        private func handleProviderProbe(_ dict: [String: Any]) {
            guard let requestId = dict["requestId"] as? String else { return }
            let providerRaw = UserDefaults.standard.string(forKey: "aiProvider") ?? AIProvider.anthropic.rawValue
            let provider = AIProvider(rawValue: providerRaw) ?? .anthropic
            let hasKey = (KeychainStore.load(account: provider.keychainAccount) ?? "").isEmpty == false
            let payload: [String: Any] = [
                "provider": provider.rawValue,
                "hasKey": hasKey,
            ]
            guard
                let idData = try? JSONSerialization.data(
                    withJSONObject: [requestId], options: [.fragmentsAllowed]
                ),
                let idStr = String(data: idData, encoding: .utf8),
                let payloadData = try? JSONSerialization.data(withJSONObject: payload),
                let payloadStr = String(data: payloadData, encoding: .utf8),
                let webView else { return }
            let idLiteral = String(idStr.dropFirst().dropLast())
            let js = "if (window.editorBridge?.aiProviderProbeResponse) { window.editorBridge.aiProviderProbeResponse(\(idLiteral), \(payloadStr)); }"
            webView.evaluateJavaScript(js, completionHandler: nil)
        }

        // MARK: - AI research

        /// Handles `ai-research-request` messages from JS. Fires the Anthropic
        /// research call (Claude + web_search) in a detached Task, then hops
        /// back to the main actor to push the result to JS via
        /// `aiResearchResponse`. Like image requests, we don't track this in
        /// `activeAITasks` — research is one-shot, the popup can be closed
        /// while it runs (Swift just drops the late response on the floor),
        /// and there's no abort path in v1.
        private func handleResearchRequest(_ dict: [String: Any]) {
            guard let requestId = dict["requestId"] as? String,
                  let query = dict["query"] as? String else {
                DebugLog.write("[research] missing requestId/query")
                return
            }
            guard EntitlementState.shared.isPro else {
                DebugLog.write("[research] \(requestId) gated — not Pro")
                NotificationCenter.default.post(name: .proPaywallRequested, object: nil)
                sendResearchResponse(requestId: requestId, result: .failure(.proRequired))
                return
            }
            let maxSearches = (dict["maxSearches"] as? Int) ?? 5
            Task { [weak self] in
                let result = await AIService.shared.runResearch(query: query, maxSearches: maxSearches)
                await MainActor.run {
                    self?.sendResearchResponse(requestId: requestId, result: result)
                }
            }
        }

        private func sendResearchResponse(requestId: String, result: Result<String, AIError>) {
            guard let webView else { return }
            let payload: [String: Any]
            switch result {
            case .success(let report):
                payload = [
                    "ok": true,
                    "report": report,
                ]
            case .failure(let err):
                payload = [
                    "ok": false,
                    "error": err.bridgeCode,
                    "message": err.userMessage,
                ]
            }
            guard
                let idData = try? JSONSerialization.data(
                    withJSONObject: [requestId], options: [.fragmentsAllowed]
                ),
                let idStr = String(data: idData, encoding: .utf8),
                let payloadData = try? JSONSerialization.data(withJSONObject: payload),
                let payloadStr = String(data: payloadData, encoding: .utf8)
            else {
                DebugLog.write("[research] failed to encode response for \(requestId)")
                return
            }
            let idLiteral = String(idStr.dropFirst().dropLast())
            let js = "if (window.editorBridge?.aiResearchResponse) { window.editorBridge.aiResearchResponse(\(idLiteral), \(payloadStr)); }"
            webView.evaluateJavaScript(js) { _, error in
                if let error {
                    DebugLog.write("[research] evaluateJavaScript aiResearchResponse failed: \(error)")
                }
            }
        }

        private func sendImageResponse(requestId: String, result: Result<URL, AIError>) {
            guard let webView else { return }
            let payload: [String: Any]
            switch result {
            case .success(let url):
                payload = [
                    "ok": true,
                    "path": url.path,
                    "url": url.absoluteString,
                ]
            case .failure(let err):
                payload = [
                    "ok": false,
                    "error": err.bridgeCode,
                    "message": err.userMessage,
                ]
            }
            guard
                let idData = try? JSONSerialization.data(
                    withJSONObject: [requestId], options: [.fragmentsAllowed]
                ),
                let idStr = String(data: idData, encoding: .utf8),
                let payloadData = try? JSONSerialization.data(withJSONObject: payload),
                let payloadStr = String(data: payloadData, encoding: .utf8)
            else {
                DebugLog.write("[ai] failed to encode image response for \(requestId)")
                return
            }
            let idLiteral = String(idStr.dropFirst().dropLast())
            let js = "if (window.editorBridge?.aiImageResponse) { window.editorBridge.aiImageResponse(\(idLiteral), \(payloadStr)); }"
            webView.evaluateJavaScript(js) { _, error in
                if let error {
                    DebugLog.write("[ai] evaluateJavaScript aiImageResponse failed: \(error)")
                }
            }
        }

        private func sendAIStreamChunk(requestId: String, delta: String) {
            guard let webView else { return }
            // JSON-encode both values via single-element arrays so quoting and
            // special characters survive the JS interpolation intact.
            guard
                let idData = try? JSONSerialization.data(
                    withJSONObject: [requestId], options: [.fragmentsAllowed]
                ),
                let idStr = String(data: idData, encoding: .utf8),
                let deltaData = try? JSONSerialization.data(
                    withJSONObject: [delta], options: [.fragmentsAllowed]
                ),
                let deltaStr = String(data: deltaData, encoding: .utf8)
            else {
                DebugLog.write("[ai] failed to encode stream chunk for \(requestId)")
                return
            }
            let idLiteral = String(idStr.dropFirst().dropLast())
            let deltaLiteral = String(deltaStr.dropFirst().dropLast())
            let js = "if (window.editorBridge?.aiStreamChunk) { window.editorBridge.aiStreamChunk(\(idLiteral), \(deltaLiteral)); }"
            webView.evaluateJavaScript(js) { _, error in
                if let error {
                    DebugLog.write("[ai] evaluateJavaScript aiStreamChunk failed: \(error)")
                }
            }
        }

        private func sendAIStreamEnd(requestId: String, result: Result<Void, AIError>) {
            guard let webView else { return }

            let payload: [String: Any]
            switch result {
            case .success:
                payload = ["ok": true]
            case .failure(let err):
                payload = [
                    "ok": false,
                    "error": err.bridgeCode,
                    "message": err.userMessage,
                ]
            }

            guard
                let idData = try? JSONSerialization.data(
                    withJSONObject: [requestId], options: [.fragmentsAllowed]
                ),
                let idStr = String(data: idData, encoding: .utf8),
                let payloadData = try? JSONSerialization.data(withJSONObject: payload),
                let payloadStr = String(data: payloadData, encoding: .utf8)
            else {
                DebugLog.write("[ai] failed to encode stream end for \(requestId)")
                return
            }
            let idLiteral = String(idStr.dropFirst().dropLast())

            // JSON is a syntactic subset of JS, so the encoded payload is safe
            // to interpolate directly as an object literal.
            let js = "if (window.editorBridge?.aiStreamEnd) { window.editorBridge.aiStreamEnd(\(idLiteral), \(payloadStr)); }"
            webView.evaluateJavaScript(js) { _, error in
                if let error {
                    DebugLog.write("[ai] evaluateJavaScript aiStreamEnd failed: \(error)")
                }
            }
        }

        private func openSettings() {
            // SwiftUI registers the Settings scene under this selector in
            // macOS 13+; using the dynamic Selector form keeps us robust to
            // any future renames.
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
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

        /// Resolves the effective locale for the editor.  Reads
        /// `Bundle.main.preferredLocalizations` which already reflects any
        /// `AppleLanguages` override the user set in Settings.
        private func currentLocaleCode() -> String {
            Bundle.main.preferredLocalizations.first ?? "en"
        }

        private func sendSetLocale(_ code: String) {
            guard let webView else { return }
            // JSON-encode to escape quotes etc; locale codes are simple but
            // this keeps the path symmetrical with sendLoad.
            let encoded: String
            if let data = try? JSONSerialization.data(
                withJSONObject: [code],
                options: [.fragmentsAllowed]
            ),
               let str = String(data: data, encoding: .utf8) {
                encoded = String(str.dropFirst().dropLast())
            } else {
                encoded = "\"en\""
            }
            let js = "if (window.editorBridge?.setLocale) { window.editorBridge.setLocale(\(encoded)); }"
            webView.evaluateJavaScript(js) { _, error in
                if let error {
                    print("evaluateJavaScript setLocale failed:", error)
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
