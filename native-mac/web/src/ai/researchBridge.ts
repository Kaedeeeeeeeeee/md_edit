/**
 * Promise wrapper around the Swift AI research message channel. Mirrors the
 * shape of `imageBridge.ts` — research is one-shot, no streaming, no abort.
 *
 * Wire protocol:
 *   JS → Swift: `{ type: "ai-research-request", requestId, query, maxSearches }`
 *   Swift → JS: `window.editorBridge.aiResearchResponse(requestId, payload)`
 *     where payload is either
 *       { ok: true; report: string }
 *     or
 *       { ok: false; error: string; message: string }.
 *
 * `report` is the assembled markdown text from all `text` content blocks the
 * model emits (Anthropic's web_search tool returns interleaved server-tool
 * blocks; Swift extracts and concatenates the text blocks in order).
 */

export type AIResearchResponse =
  | { ok: true; report: string }
  | { ok: false; error: string; message: string };

export type AIProviderProbe = {
  provider: "anthropic" | "openai";
  hasKey: boolean;
};

interface PendingResearch {
  resolve: (response: AIResearchResponse) => void;
}

interface PendingProbe {
  resolve: (response: AIProviderProbe) => void;
}

const pendingResearch = new Map<string, PendingResearch>();
const pendingProbes = new Map<string, PendingProbe>();

function genRequestId(): string {
  if (typeof crypto !== "undefined" && typeof crypto.randomUUID === "function") {
    return crypto.randomUUID();
  }
  return `r-${Date.now()}-${Math.random().toString(36).slice(2, 8)}`;
}

/**
 * Installs the `aiResearchResponse` callback Swift calls when a request
 * settles. Returns a cleanup that restores the previous handler — matches
 * `installImageBridge` so the React useEffect cleanup story is identical.
 */
export function installResearchBridge(): () => void {
  const bridge = window.editorBridge;
  if (!bridge) {
    console.warn("[research] editorBridge not initialized; installResearchBridge no-op");
    return () => {};
  }
  const previousResearch = bridge.aiResearchResponse;
  const previousProbe = bridge.aiProviderProbeResponse;

  const researchHandler = (requestId: string, payload: AIResearchResponse) => {
    const pending = pendingResearch.get(requestId);
    if (pending) {
      pendingResearch.delete(requestId);
      pending.resolve(payload);
    }
    // Late responses (popup closed before request completed) fall on the
    // floor — no entry, no resolution. The Promise was already abandoned by
    // its caller via the popup's `activeRequestRef` pattern.
  };
  const probeHandler = (requestId: string, payload: AIProviderProbe) => {
    const pending = pendingProbes.get(requestId);
    if (pending) {
      pendingProbes.delete(requestId);
      pending.resolve(payload);
    }
  };

  bridge.aiResearchResponse = researchHandler;
  bridge.aiProviderProbeResponse = probeHandler;
  return () => {
    if (window.editorBridge?.aiResearchResponse === researchHandler) {
      window.editorBridge.aiResearchResponse = previousResearch;
    }
    if (window.editorBridge?.aiProviderProbeResponse === probeHandler) {
      window.editorBridge.aiProviderProbeResponse = previousProbe;
    }
  };
}

/**
 * Synchronous-feeling probe to read the configured provider + key presence.
 * Cheap (Swift just reads UserDefaults + Keychain on the main actor), used
 * by the research popup to gate the UI on Anthropic before submitting.
 */
export function probeProvider(): Promise<AIProviderProbe> {
  return new Promise<AIProviderProbe>((resolve) => {
    const requestId = genRequestId();
    const host = window.webkit?.messageHandlers?.editor;
    if (!host) {
      // Outside the desktop app — pretend Anthropic with no key so the popup
      // shows the missing-key UI rather than the wrong-provider UI.
      queueMicrotask(() =>
        resolve({ provider: "anthropic", hasKey: false }),
      );
      return;
    }
    pendingProbes.set(requestId, { resolve });
    host.postMessage({ type: "ai-provider-probe", requestId });
  });
}

/**
 * Fires a research request. Resolves with the terminal payload. Never throws
 * — host-not-available is reported as a structured error so the caller has
 * a single code path.
 */
export function sendResearchRequest(
  query: string,
  maxSearches: number,
): Promise<AIResearchResponse> {
  return new Promise<AIResearchResponse>((resolve) => {
    const requestId = genRequestId();
    const host = window.webkit?.messageHandlers?.editor;
    if (!host) {
      queueMicrotask(() =>
        resolve({
          ok: false,
          error: "no-host",
          message: "Research is only available inside the desktop app.",
        }),
      );
      return;
    }
    pendingResearch.set(requestId, { resolve });
    host.postMessage({
      type: "ai-research-request",
      requestId,
      query,
      maxSearches,
    });
  });
}
