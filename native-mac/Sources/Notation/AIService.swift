import Foundation

enum AIProvider: String, CaseIterable, Identifiable {
    case anthropic
    case openai

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .anthropic: return "Anthropic Claude"
        case .openai: return "OpenAI / Compatible"
        }
    }

    var keychainAccount: String { rawValue }

    var defaultModel: String {
        switch self {
        case .anthropic: return "claude-sonnet-4-6"
        case .openai: return "gpt-4.1"
        }
    }

    /// Default API base URL — only meaningful for OpenAI-compatible providers.
    /// Anthropic's API has no compatible peer so we don't expose this for it.
    var defaultBaseURL: String {
        switch self {
        case .anthropic: return "https://api.anthropic.com/v1"
        case .openai: return "https://api.openai.com/v1"
        }
    }

    /// UserDefaults key for the persisted model name.
    var modelDefaultsKey: String {
        switch self {
        case .anthropic: return "aiAnthropicModel"
        case .openai: return "aiOpenAIModel"
        }
    }

    /// UserDefaults key for the persisted base URL (OpenAI-compat only).
    var baseURLDefaultsKey: String {
        "aiOpenAIBaseURL"
    }
}

/// Reads the user-overridden model name, falling back to the provider default
/// if nothing was saved or the saved value is empty.
func resolvedModel(for provider: AIProvider) -> String {
    let stored = UserDefaults.standard.string(forKey: provider.modelDefaultsKey) ?? ""
    let trimmed = stored.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? provider.defaultModel : trimmed
}

/// Reads the user-overridden base URL for OpenAI-compatible providers.
func resolvedOpenAIBaseURL() -> String {
    let stored = UserDefaults.standard.string(forKey: AIProvider.openai.baseURLDefaultsKey) ?? ""
    let trimmed = stored.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? AIProvider.openai.defaultBaseURL : trimmed
}

enum AIError: Error {
    case missingKey
    case http(Int, String)
    case decode(String)
    case network(Error)
    case cancelled
    /// User is not on Notation Pro. AIService never returns this directly;
    /// it's synthesized by the gating layer (EditorWebView /
    /// AgentChatController) so the JS bridge / chat UI can route errors
    /// through the same channel.
    case proRequired

    var bridgeCode: String {
        switch self {
        case .missingKey: return "missing-key"
        case .http(let status, _): return "http-\(status)"
        case .decode: return "decode-error"
        case .network: return "network-error"
        case .cancelled: return "cancelled"
        case .proRequired: return "pro-required"
        }
    }

    var userMessage: String {
        switch self {
        case .missingKey:
            return "No API key set. Open Settings → AI."
        case .http(let status, let body):
            let snippet = body.prefix(160)
            return "Server error (\(status)). \(snippet)"
        case .decode(let detail):
            return "Could not parse the AI response. \(detail)"
        case .network(let err):
            return "Network error: \(err.localizedDescription)"
        case .cancelled:
            return "Cancelled."
        case .proRequired:
            return String(localized: "AI 功能需要升级到 Notation Pro。")
        }
    }
}

/// An incremental event emitted by a provider's streaming endpoint.
/// Exactly one of `.completed` or `.failed` is the terminal event.
enum AIStreamEvent {
    case delta(String)
    case completed
    case failed(AIError)
}

protocol AIProviderClient {
    func stream(
        system: String,
        messages: [(role: String, content: String)],
        apiKey: String
    ) -> AsyncStream<AIStreamEvent>
}

/// Streaming connections live longer than the original single-shot timeout —
/// reasoning models, long generations, slow providers all bump up against the
/// old 60s ceiling.
private let streamingTimeout: TimeInterval = 120

/// Reads up to ~2KB of an SSE body for an error response so we can surface the
/// server's actual error JSON instead of just the HTTP code.
private func collectErrorBody(_ bytes: URLSession.AsyncBytes) async -> String {
    var collected = ""
    do {
        for try await line in bytes.lines {
            collected += line + "\n"
            if collected.count > 2000 { break }
        }
    } catch {
        // Best effort — return whatever we already collected.
    }
    return collected
}

struct AnthropicClient: AIProviderClient {
    let model: String
    let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    func stream(
        system: String,
        messages: [(role: String, content: String)],
        apiKey: String
    ) -> AsyncStream<AIStreamEvent> {
        AsyncStream { continuation in
            let task = Task {
                var request = URLRequest(url: endpoint)
                request.httpMethod = "POST"
                request.timeoutInterval = streamingTimeout
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
                request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

                let body: [String: Any] = [
                    "model": model,
                    "max_tokens": 2048,
                    "system": system,
                    "stream": true,
                    "messages": messages.map { ["role": $0.role, "content": $0.content] },
                ]
                do {
                    request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])
                } catch {
                    continuation.yield(.failed(.decode("request encode failed: \(error.localizedDescription)")))
                    continuation.finish()
                    return
                }

                do {
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    if Task.isCancelled {
                        continuation.yield(.failed(.cancelled))
                        continuation.finish()
                        return
                    }
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    if status != 200 {
                        let body = await collectErrorBody(bytes)
                        continuation.yield(.failed(.http(status, body)))
                        continuation.finish()
                        return
                    }

                    // Anthropic SSE framing: `event: <name>\n` then `data: {…}\n\n`.
                    // The empty line resets `currentEvent`. Other event types
                    // (`message_start`, `content_block_start`, `ping`,
                    // `message_delta`, `message_stop`) are ignored — we only
                    // care about `content_block_delta` for text streaming.
                    var currentEvent: String? = nil
                    for try await line in bytes.lines {
                        if Task.isCancelled {
                            continuation.yield(.failed(.cancelled))
                            continuation.finish()
                            return
                        }
                        if line.isEmpty {
                            currentEvent = nil
                            continue
                        }
                        if line.hasPrefix("event: ") {
                            currentEvent = String(line.dropFirst("event: ".count))
                            continue
                        }
                        if line.hasPrefix("data: ") {
                            let payload = String(line.dropFirst("data: ".count))
                            if currentEvent == "content_block_delta",
                               let data = payload.data(using: .utf8),
                               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                               let delta = json["delta"] as? [String: Any],
                               let type = delta["type"] as? String, type == "text_delta",
                               let text = delta["text"] as? String, !text.isEmpty {
                                continuation.yield(.delta(text))
                            }
                            // All other event payloads (ping, message_start,
                            // content_block_start, message_delta, message_stop)
                            // are intentionally dropped.
                        }
                    }
                    continuation.yield(.completed)
                    continuation.finish()
                } catch {
                    if Task.isCancelled {
                        continuation.yield(.failed(.cancelled))
                    } else {
                        continuation.yield(.failed(.network(error)))
                    }
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

struct OpenAIClient: AIProviderClient {
    let baseURL: String
    let model: String

    /// Trim trailing slashes and append `/chat/completions`. Accepts both
    /// `https://api.deepseek.com/v1` and `https://api.deepseek.com/v1/`
    /// without doubling the slash.
    var endpoint: URL? {
        var url = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while url.hasSuffix("/") { url.removeLast() }
        return URL(string: url + "/chat/completions")
    }

    func stream(
        system: String,
        messages: [(role: String, content: String)],
        apiKey: String
    ) -> AsyncStream<AIStreamEvent> {
        AsyncStream { continuation in
            let task = Task {
                guard let url = endpoint else {
                    continuation.yield(.failed(.decode("Invalid base URL: \(baseURL)")))
                    continuation.finish()
                    return
                }

                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.timeoutInterval = streamingTimeout
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

                let openAIMessages: [[String: String]] =
                    [["role": "system", "content": system]]
                    + messages.map { ["role": $0.role, "content": $0.content] }

                let body: [String: Any] = [
                    "model": model,
                    "messages": openAIMessages,
                    "stream": true,
                ]
                do {
                    request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])
                } catch {
                    continuation.yield(.failed(.decode("request encode failed: \(error.localizedDescription)")))
                    continuation.finish()
                    return
                }

                do {
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    if Task.isCancelled {
                        continuation.yield(.failed(.cancelled))
                        continuation.finish()
                        return
                    }
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    if status != 200 {
                        let body = await collectErrorBody(bytes)
                        continuation.yield(.failed(.http(status, body)))
                        continuation.finish()
                        return
                    }

                    // OpenAI SSE framing: `data: {…}\n\n`, terminated by a
                    // `data: [DONE]\n\n` sentinel. The first `delta` object
                    // usually carries `role` (skip); subsequent ones carry
                    // `content` (yield). `refusal` and other inline fields
                    // are ignored for v1.
                    for try await line in bytes.lines {
                        if Task.isCancelled {
                            continuation.yield(.failed(.cancelled))
                            continuation.finish()
                            return
                        }
                        guard line.hasPrefix("data: ") else { continue }
                        let payload = String(line.dropFirst("data: ".count))
                        if payload == "[DONE]" {
                            continuation.yield(.completed)
                            continuation.finish()
                            return
                        }
                        if let data = payload.data(using: .utf8),
                           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                           let choices = json["choices"] as? [[String: Any]],
                           let first = choices.first,
                           let delta = first["delta"] as? [String: Any],
                           let content = delta["content"] as? String, !content.isEmpty {
                            continuation.yield(.delta(content))
                        }
                    }
                    // Stream closed without an explicit [DONE]. Treat as a
                    // normal completion — some compatible providers omit it.
                    continuation.yield(.completed)
                    continuation.finish()
                } catch {
                    if Task.isCancelled {
                        continuation.yield(.failed(.cancelled))
                    } else {
                        continuation.yield(.failed(.network(error)))
                    }
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Saves image data to the app's sandbox `Documents/notation-images` dir and
/// returns the resulting file URL. Returns nil on failure.
///
/// Known limitation (documented in plan): the file lives in the app sandbox,
/// not next to the user's .md file. If the user moves the document outside
/// the sandbox the image links break. We accept this for v1.
private func saveImageToSandbox(data: Data, ext: String) -> URL? {
    let documents = NSHomeDirectory() + "/Documents/notation-images"
    try? FileManager.default.createDirectory(atPath: documents, withIntermediateDirectories: true)
    let filename = "img-\(UUID().uuidString).\(ext)"
    let url = URL(fileURLWithPath: documents).appendingPathComponent(filename)
    do {
        try data.write(to: url, options: .atomic)
        return url
    } catch {
        DebugLog.write("[ai] saveImageToSandbox failed: \(error.localizedDescription)")
        return nil
    }
}

extension OpenAIClient {
    /// Generates an image via OpenAI's `/v1/images/generations` endpoint and
    /// returns the local sandbox URL of the saved image. The model is
    /// hardcoded to `gpt-image-1` per the v1 design — that response format
    /// returns base64 data inline, but we also handle the `url` fallback for
    /// providers that prefer hosted-URL responses.
    ///
    /// For custom OpenAI-compatible providers (DeepSeek etc.) we still hit
    /// `<baseURL>/images/generations` — most don't support it and will return
    /// an HTTP error, which we surface as `.http(_, _)` so the popup can show
    /// the server message.
    func generateImage(prompt: String, apiKey: String) async -> Result<URL, AIError> {
        let imagesURL: URL = {
            var u = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            while u.hasSuffix("/") { u.removeLast() }
            return URL(string: u + "/images/generations") ?? URL(string: "https://api.openai.com/v1/images/generations")!
        }()

        var request = URLRequest(url: imagesURL)
        request.httpMethod = "POST"
        // Image generation can take 30s+ for high quality outputs; give it
        // generous headroom relative to the streaming text timeout.
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let body: [String: Any] = [
            "model": "gpt-image-1",
            "prompt": prompt,
            "size": "1024x1024",
            "n": 1,
        ]
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])
        } catch {
            return .failure(.decode("encode failed: \(error.localizedDescription)"))
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else {
                let bodyStr = String(data: data, encoding: .utf8) ?? ""
                return .failure(.http(status, bodyStr))
            }
            guard
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let dataArray = json["data"] as? [[String: Any]],
                let first = dataArray.first
            else {
                return .failure(.decode("missing data[0]"))
            }
            // gpt-image-1 returns base64 by default; older `dall-e-*` style
            // responses use `url`. Handle both.
            if let b64 = first["b64_json"] as? String, let raw = Data(base64Encoded: b64) {
                if let tmpURL = saveImageToSandbox(data: raw, ext: "png") {
                    return .success(tmpURL)
                }
                return .failure(.decode("could not write image to sandbox"))
            }
            if let urlString = first["url"] as? String, let url = URL(string: urlString) {
                do {
                    let (imgData, _) = try await URLSession.shared.data(from: url)
                    if let tmpURL = saveImageToSandbox(data: imgData, ext: "png") {
                        return .success(tmpURL)
                    }
                    return .failure(.decode("could not write downloaded image"))
                } catch {
                    return .failure(.network(error))
                }
            }
            return .failure(.decode("response had neither b64_json nor url"))
        } catch {
            return .failure(.network(error))
        }
    }
}

actor AIService {
    static let shared = AIService()

    private static let systemPrompt = """
        You are a writing assistant embedded in a Markdown editor. Rewrite or transform ONLY the SELECTED text according to the user's INSTRUCTION. The BEFORE and AFTER blocks are context only — never repeat them in your reply. Reply with the rewritten Markdown only, with no preamble, no surrounding quotes, and no explanations. If the SELECTED text is empty, treat the INSTRUCTION as a request to generate fresh Markdown content.
        """

    /// Streams the AI response, calling `onDelta` for each text chunk and
    /// `onComplete` exactly once with the terminal status.
    ///
    /// Callbacks run on the main actor — callers building UI off them don't
    /// need to hop threads. Cancellation: the returned work is driven by a
    /// `Task` the caller spawned; cancelling that Task also cancels the
    /// underlying URLSession stream via `AsyncStream.onTermination`.
    func runStreamingRequest(
        userPrompt: String,
        selectedMarkdown: String,
        contextBefore: String,
        contextAfter: String,
        messages: [(role: String, content: String)]? = nil,
        systemPrompt: String? = nil,
        onDelta: @MainActor @Sendable (String) -> Void,
        onComplete: @MainActor @Sendable (Result<Void, AIError>) -> Void
    ) async {
        let providerRaw = UserDefaults.standard.string(forKey: "aiProvider") ?? AIProvider.anthropic.rawValue
        let provider = AIProvider(rawValue: providerRaw) ?? .anthropic

        guard let apiKey = KeychainStore.load(account: provider.keychainAccount),
              !apiKey.isEmpty
        else {
            DebugLog.write("[ai] missing key for \(provider.rawValue)")
            await MainActor.run { onComplete(.failure(.missingKey)) }
            return
        }

        // Build the final messages array: either use the caller-supplied
        // multi-turn history as-is, or fall back to the single-shot template.
        let finalMessages: [(role: String, content: String)]
        if let messages, !messages.isEmpty {
            finalMessages = messages
        } else {
            let composedUser = """
                INSTRUCTION:
                \(userPrompt)

                BEFORE:
                \(contextBefore)

                SELECTED:
                \(selectedMarkdown)

                AFTER:
                \(contextAfter)
                """
            finalMessages = [(role: "user", content: composedUser)]
        }

        let model = resolvedModel(for: provider)
        DebugLog.write("[ai] streaming request provider=\(provider.rawValue) model=\(model) turns=\(messages?.count ?? 1)")

        let client: AIProviderClient = {
            switch provider {
            case .anthropic:
                return AnthropicClient(model: model)
            case .openai:
                return OpenAIClient(baseURL: resolvedOpenAIBaseURL(), model: model)
            }
        }()

        let stream = client.stream(
            system: systemPrompt ?? Self.systemPrompt,
            messages: finalMessages,
            apiKey: apiKey
        )

        var deltaCount = 0
        var totalChars = 0
        for await event in stream {
            if Task.isCancelled {
                await MainActor.run { onComplete(.failure(.cancelled)) }
                return
            }
            switch event {
            case .delta(let chunk):
                deltaCount += 1
                totalChars += chunk.count
                await MainActor.run { onDelta(chunk) }
            case .completed:
                DebugLog.write("[ai] stream completed deltas=\(deltaCount) chars=\(totalChars)")
                await MainActor.run { onComplete(.success(())) }
                return
            case .failed(let err):
                DebugLog.write("[ai] stream failed code=\(err.bridgeCode)")
                await MainActor.run { onComplete(.failure(err)) }
                return
            }
        }
        // AsyncStream finished without a terminal event — shouldn't happen, but
        // treat it as a successful completion to release the UI.
        DebugLog.write("[ai] stream ended without terminal event; treating as completed")
        await MainActor.run { onComplete(.success(())) }
    }

    /// One-shot, non-streaming research call. Uses Anthropic's `web_search`
    /// server tool to gather sources and synthesize a markdown report.
    ///
    /// Restrictions:
    ///   - Research is Anthropic-only in v1. OpenAI's tool calling for web
    ///     search isn't equivalent — caller is expected to gate on provider
    ///     in the popup, but we re-check here so a stale UI state can't
    ///     accidentally fire against an OpenAI key.
    ///   - Non-streaming on purpose: `web_search` is a server tool whose
    ///     result blocks interleave with text, so we wait for the full
    ///     response and extract all `text` content blocks. Citations live
    ///     inside the text blocks Claude emits — we don't parse them out.
    func runResearch(query: String, maxSearches: Int) async -> Result<String, AIError> {
        let providerRaw = UserDefaults.standard.string(forKey: "aiProvider") ?? AIProvider.anthropic.rawValue
        let provider = AIProvider(rawValue: providerRaw) ?? .anthropic
        guard provider == .anthropic else {
            return .failure(.decode("Research Mode currently requires Anthropic Claude. Switch provider in Settings → AI."))
        }
        guard let apiKey = KeychainStore.load(account: provider.keychainAccount),
              !apiKey.isEmpty else {
            DebugLog.write("[research] missing key")
            return .failure(.missingKey)
        }
        let model = resolvedModel(for: provider)
        DebugLog.write("[research] starting query=\(query.prefix(80)) maxSearches=\(maxSearches) model=\(model)")

        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        // Research calls can run ~60s while the server is making multiple
        // web_search tool calls; give it generous headroom.
        request.timeoutInterval = 180
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        let systemPrompt = """
            You are a research assistant. Use the web_search tool to gather current, accurate information about the user's query. Use multiple searches if needed to cover different angles. After searching, write a comprehensive but concise markdown report with these sections:
            - **Summary**: 2-3 sentence overview
            - **Key findings**: bullet list of the most important points, each with inline citations like [Source 1](url)
            - **Details**: 2-4 short paragraphs expanding on the findings
            - **Sources**: numbered list of the sources you used, with titles and URLs

            Reply with the markdown report only. No preamble, no "Here is the report:".
            """

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 4096,
            "system": systemPrompt,
            "messages": [["role": "user", "content": query]],
            "tools": [
                [
                    "type": "web_search_20250305",
                    "name": "web_search",
                    "max_uses": maxSearches,
                ]
            ],
        ]
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])
        } catch {
            return .failure(.decode("encode failed: \(error.localizedDescription)"))
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else {
                let bodyStr = String(data: data, encoding: .utf8) ?? ""
                DebugLog.write("[research] HTTP \(status): \(bodyStr.prefix(200))")
                return .failure(.http(status, bodyStr))
            }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let content = json["content"] as? [[String: Any]] else {
                return .failure(.decode("missing content array"))
            }
            // The response mixes `text`, `server_tool_use`, and
            // `web_search_tool_result` blocks. For v1 we concatenate every
            // text block in order — Claude embeds citations directly inside
            // the text it emits, so the assembled string is a complete
            // markdown report.
            var report = ""
            for block in content {
                if let type = block["type"] as? String, type == "text",
                   let text = block["text"] as? String, !text.isEmpty {
                    if !report.isEmpty { report += "\n\n" }
                    report += text
                }
            }
            if report.isEmpty {
                return .failure(.decode("model returned no text content"))
            }
            DebugLog.write("[research] success len=\(report.count)")
            return .success(report)
        } catch {
            return .failure(.network(error))
        }
    }

    /// One-shot, non-streaming image generation. Returns the file URL of the
    /// downloaded image, saved in the app sandbox under
    /// `~/Documents/notation-images/`.
    ///
    /// Restrictions:
    ///   - Image gen is OpenAI-only in v1. Anthropic has no image API, so we
    ///     fail fast with a `.decode` error carrying a user-visible message
    ///     when the active provider is Anthropic.
    ///   - The model is hardcoded to `gpt-image-1` (see `OpenAIClient`).
    func runImageGeneration(prompt: String) async -> Result<URL, AIError> {
        let providerRaw = UserDefaults.standard.string(forKey: "aiProvider") ?? AIProvider.anthropic.rawValue
        let provider = AIProvider(rawValue: providerRaw) ?? .anthropic
        guard provider == .openai else {
            return .failure(.decode("Image generation requires the OpenAI provider. Set it in Settings → AI."))
        }
        guard let apiKey = KeychainStore.load(account: provider.keychainAccount),
              !apiKey.isEmpty else {
            DebugLog.write("[ai] image gen missing key")
            return .failure(.missingKey)
        }
        let client = OpenAIClient(baseURL: resolvedOpenAIBaseURL(), model: resolvedModel(for: provider))
        DebugLog.write("[ai] image gen prompt=\(prompt.prefix(80))")
        let result = await client.generateImage(prompt: prompt, apiKey: apiKey)
        switch result {
        case .success(let url): DebugLog.write("[ai] image success path=\(url.lastPathComponent)")
        case .failure(let err): DebugLog.write("[ai] image failure code=\(err.bridgeCode)")
        }
        return result
    }
}
