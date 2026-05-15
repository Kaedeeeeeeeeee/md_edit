/**
 * Promise / callback wrappers around the Swift AI message channel.
 *
 * Two surfaces:
 *  - `sendAIRequestStream(...)` — callback-based streaming. The host calls
 *    `window.editorBridge.aiStreamChunk(id, delta)` for each token, and
 *    finally `window.editorBridge.aiStreamEnd(id, result)`. Returns a
 *    `StreamHandle` whose `abort()` cancels the underlying URLSession on the
 *    Swift side.
 *  - `sendAIRequest(...)` — promise-based, returns the accumulated full text.
 *    Internally just collects deltas from `sendAIRequestStream`. Kept for
 *    backwards compat with call sites that don't need progressive rendering.
 *
 * Error handling and the missing-host (`no-host`) early bailout still flow
 * through the stream path so both surfaces report failures uniformly.
 *
 * Important: we **never overwrite** `window.editorBridge` — only extend it,
 * because EmbeddedEditor's existing useEffect also writes to it.
 */

export type AISuccessResponse = { ok: true; text: string };
export type AIErrorResponse = { ok: false; error: string; message: string };
export type AIResponse = AISuccessResponse | AIErrorResponse;

export type AIStreamResult =
  | { ok: true }
  | { ok: false; error: string; message: string };

export type AIChatMessage = { role: "user" | "assistant"; content: string };

export interface AIRequestPayload {
  // Mutually exclusive: provide EITHER `prompt` (single-shot) OR `messages` (multi-turn).
  // If `messages` is provided, the Swift side ignores the BEFORE/SELECTED/AFTER template
  // and uses the messages array directly. `selectedMarkdown`/`contextBefore`/`contextAfter`
  // are still sent so Swift can fold them into the FIRST user message if needed
  // (current implementation: when `messages` is present, Swift uses them as-is
  // and the SELECTED/BEFORE/AFTER context is expected to already be embedded
  // in the caller's first user message).
  prompt?: string;
  messages?: AIChatMessage[];
  selectedMarkdown: string;
  contextBefore: string;
  contextAfter: string;
}

export interface StreamHandle {
  /**
   * Asks Swift to cancel the in-flight request (Task.cancel() → URLSession
   * cancel → AsyncStream termination) and unregisters the local listener so
   * any late deltas that already crossed the bridge are dropped.
   */
  abort: () => void;
}

interface PendingStream {
  onDelta: (chunk: string) => void;
  onEnd: (result: AIStreamResult) => void;
}

// The `Window.editorBridge` shape (including `aiResponse`, `aiStreamChunk`,
// `aiStreamEnd`) is declared in EmbeddedEditor.tsx as the single source of
// truth; we just consume it here.

const pendingStreams = new Map<string, PendingStream>();

function genRequestId(): string {
  // crypto.randomUUID is available in WKWebView (modern Safari).
  if (typeof crypto !== "undefined" && typeof crypto.randomUUID === "function") {
    return crypto.randomUUID();
  }
  // Fallback — only triggers on truly ancient WebKits, which we don't ship to.
  return `ai-${Date.now()}-${Math.random().toString(36).slice(2, 10)}`;
}

/**
 * Installs the bridge callbacks Swift invokes during a streaming response.
 * Idempotent in practice (multiple mounts overwrite previous handlers and
 * the returned cleanup restores them).
 */
export function installAIBridge(): () => void {
  const bridge = window.editorBridge;
  if (!bridge) {
    console.warn("[ai] editorBridge not initialized; installAIBridge no-op");
    return () => {};
  }

  const previousChunk = bridge.aiStreamChunk;
  const previousEnd = bridge.aiStreamEnd;
  const previousResponse = bridge.aiResponse;

  const chunkHandler = (requestId: string, delta: string) => {
    const entry = pendingStreams.get(requestId);
    if (entry) {
      entry.onDelta(delta);
    } else {
      // Late delta after abort — silently drop. Logged at debug level to keep
      // the console quiet under aborts during fast typing.
      // console.debug("[ai] stream chunk for unknown requestId:", requestId);
    }
  };
  const endHandler = (requestId: string, payload: AIStreamResult) => {
    const entry = pendingStreams.get(requestId);
    if (entry) {
      pendingStreams.delete(requestId);
      entry.onEnd(payload);
    } else {
      // Same as above — request was aborted or popup closed before the end
      // marker arrived. No-op.
    }
  };
  // Back-compat: legacy non-streaming responses (if any future code path
  // emits them) are funneled through the stream pipeline by synthesizing
  // a single delta + completed end event.
  const responseHandler = (requestId: string, payload: AIResponse) => {
    const entry = pendingStreams.get(requestId);
    if (!entry) {
      console.warn("[ai] response for unknown requestId:", requestId);
      return;
    }
    if (payload.ok) {
      entry.onDelta(payload.text);
      pendingStreams.delete(requestId);
      entry.onEnd({ ok: true });
    } else {
      pendingStreams.delete(requestId);
      entry.onEnd({ ok: false, error: payload.error, message: payload.message });
    }
  };

  bridge.aiStreamChunk = chunkHandler;
  bridge.aiStreamEnd = endHandler;
  bridge.aiResponse = responseHandler;

  return () => {
    if (window.editorBridge?.aiStreamChunk === chunkHandler) {
      window.editorBridge.aiStreamChunk = previousChunk;
    }
    if (window.editorBridge?.aiStreamEnd === endHandler) {
      window.editorBridge.aiStreamEnd = previousEnd;
    }
    if (window.editorBridge?.aiResponse === responseHandler) {
      window.editorBridge.aiResponse = previousResponse;
    }
  };
}

/**
 * Streaming request. `onDelta` is called for each text chunk; `onEnd` exactly
 * once with the terminal status. Returns a handle whose `abort()` cancels
 * both the local listener and the Swift-side URLSession.
 *
 * If the WKWebView host isn't reachable (e.g. running the editor outside the
 * native app), `onEnd` is invoked synchronously on the next microtask with a
 * `no-host` error and the returned handle is a no-op.
 */
export function sendAIRequestStream(
  payload: AIRequestPayload,
  onDelta: (chunk: string) => void,
  onEnd: (result: AIStreamResult) => void,
): StreamHandle {
  const requestId = genRequestId();
  const host = window.webkit?.messageHandlers?.editor;

  if (!host) {
    queueMicrotask(() =>
      onEnd({
        ok: false,
        error: "no-host",
        message: "AI is only available inside the desktop app.",
      }),
    );
    return { abort: () => {} };
  }

  pendingStreams.set(requestId, { onDelta, onEnd });
  host.postMessage({
    type: "ai-request",
    requestId,
    prompt: payload.prompt,
    messages: payload.messages,
    selectedMarkdown: payload.selectedMarkdown,
    contextBefore: payload.contextBefore,
    contextAfter: payload.contextAfter,
  });

  return {
    abort: () => {
      // Drop our local listener first so any late deltas already in flight
      // are ignored. Then tell Swift to cancel — it will stop emitting.
      if (pendingStreams.delete(requestId)) {
        window.webkit?.messageHandlers?.editor?.postMessage({
          type: "ai-abort",
          requestId,
        });
      }
    },
  };
}

/**
 * Promise-based facade over `sendAIRequestStream` — accumulates all deltas
 * and resolves with the full text. Use this when you don't need progressive
 * rendering. Visible streaming requires `sendAIRequestStream`.
 */
export function sendAIRequest(payload: AIRequestPayload): Promise<AIResponse> {
  return new Promise<AIResponse>((resolve) => {
    let acc = "";
    sendAIRequestStream(
      payload,
      (chunk) => {
        acc += chunk;
      },
      (result) => {
        if (result.ok) {
          resolve({ ok: true, text: acc });
        } else {
          resolve({ ok: false, error: result.error, message: result.message });
        }
      },
    );
  });
}

export function openSettings(): void {
  window.webkit?.messageHandlers?.editor?.postMessage({ type: "open-settings" });
}
