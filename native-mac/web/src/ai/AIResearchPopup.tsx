import { useCallback, useEffect, useRef, useState } from "react";
import {
  sendResearchRequest,
  probeProvider,
  type AIResearchResponse,
  type AIProviderProbe,
} from "./researchBridge";
import { openSettings } from "./aiBridge";

// eslint-disable-next-line @typescript-eslint/no-explicit-any
type AnyEditor = any;

export interface AIResearchPopupProps {
  editor: AnyEditor;
  onClose: () => void;
}

type State =
  | { kind: "probing" }
  | { kind: "provider-gate" }
  | { kind: "input" }
  | { kind: "loading"; query: string; maxSearches: number }
  | { kind: "preview"; query: string; maxSearches: number; report: string }
  | {
      kind: "error";
      query: string;
      maxSearches: number;
      error: string;
      message: string;
    };

const MAX_SEARCH_OPTIONS = [3, 5, 10] as const;

/**
 * Modal-ish popup for the Research Mode flow. Triggered from the AI →
 * Research… menu item, which routes through Swift → bridge.openResearch.
 *
 * State machine:
 *   probing → (anthropic + key) → input → loading → preview → (insert | copy | discard)
 *                                                          ↘ error → (retry | settings | close)
 *           → (openai or missing key) → provider-gate → (open settings | close)
 *
 * Insertion appends the markdown report as a new section at the end of the
 * document, so it never overwrites in-progress work. The popup positions
 * itself top-center, fixed at 80px from the top, 560px wide — wider than the
 * image popup because reports are text-heavy.
 */
export function AIResearchPopup({ editor, onClose }: AIResearchPopupProps) {
  const [state, setState] = useState<State>({ kind: "probing" });
  const [query, setQuery] = useState("");
  const [maxSearches, setMaxSearches] = useState<number>(5);
  const textareaRef = useRef<HTMLTextAreaElement | null>(null);
  // Drop late responses if the user discarded / closed / retried — same idea
  // as AIImagePopup.activeRequestRef.
  const activeRequestRef = useRef(0);

  // On mount, probe the provider so we can either show input or the gate.
  useEffect(() => {
    let cancelled = false;
    probeProvider().then((probe: AIProviderProbe) => {
      if (cancelled) return;
      if (probe.provider !== "anthropic") {
        setState({ kind: "provider-gate" });
      } else {
        setState({ kind: "input" });
      }
    });
    return () => {
      cancelled = true;
    };
  }, []);

  // Focus the textarea when input becomes active.
  useEffect(() => {
    if (state.kind === "input") {
      // Defer one tick so the element exists after state transition.
      const id = window.setTimeout(() => textareaRef.current?.focus(), 0);
      return () => window.clearTimeout(id);
    }
  }, [state.kind]);

  // Escape closes the popup at any time.
  useEffect(() => {
    function onKey(e: KeyboardEvent) {
      if (e.key === "Escape") onClose();
    }
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [onClose]);

  const submit = useCallback((q: string, m: number) => {
    const trimmed = q.trim();
    if (!trimmed) return;
    const requestNum = ++activeRequestRef.current;
    setState({ kind: "loading", query: trimmed, maxSearches: m });
    sendResearchRequest(trimmed, m).then((response: AIResearchResponse) => {
      if (requestNum !== activeRequestRef.current) return;
      if (response.ok) {
        setState({
          kind: "preview",
          query: trimmed,
          maxSearches: m,
          report: response.report,
        });
      } else {
        setState({
          kind: "error",
          query: trimmed,
          maxSearches: m,
          error: response.error,
          message: response.message,
        });
      }
    });
  }, []);

  function cancelLoading() {
    // Fire-and-forget: increment the active ref so a late response is
    // dropped, but the Swift task keeps running and is harmless. The popup
    // closes.
    activeRequestRef.current++;
    onClose();
  }

  function discard() {
    activeRequestRef.current++;
    onClose();
  }

  function insert(report: string) {
    insertReportSection(editor, report);
    onClose();
  }

  function copy(report: string) {
    // Clipboard API works in WKWebView under user-activation; this fires
    // from a click handler so the activation is satisfied.
    navigator.clipboard.writeText(report).catch(() => {
      // Best-effort; if it fails we still close the popup.
    });
  }

  return (
    <div
      className="lg-ai-popup"
      style={{
        position: "fixed",
        top: 80,
        left: "50%",
        transform: "translateX(-50%)",
        zIndex: 9999,
        width: 560,
        maxWidth: "calc(100vw - 32px)",
      }}
      role="dialog"
      aria-label="AI Research"
    >
      {state.kind === "probing" && (
        <div className="lg-ai-row">
          <div className="lg-ai-loader" aria-hidden="true">
            <span /><span /><span />
          </div>
          <div className="lg-ai-status">Loading…</div>
        </div>
      )}

      {state.kind === "provider-gate" && (
        <div className="lg-ai-preview">
          <div className="lg-ai-error">
            Research Mode currently requires Anthropic Claude. Switch provider
            in Settings → AI.
          </div>
          <div className="lg-ai-actions">
            <button
              type="button"
              className="lg-ai-primary"
              onMouseDown={(e) => e.preventDefault()}
              onClick={() => {
                openSettings();
                onClose();
              }}
            >
              Open Settings
            </button>
            <div style={{ flex: 1 }} />
            <button
              type="button"
              className="lg-ai-secondary"
              onMouseDown={(e) => e.preventDefault()}
              onClick={onClose}
            >
              Close
            </button>
          </div>
        </div>
      )}

      {state.kind === "input" && (
        <>
          <div className="lg-ai-row">
            <textarea
              ref={textareaRef}
              className="lg-ai-input lg-ai-research-textarea"
              placeholder="What would you like to research? (e.g. recent advances in solid-state batteries, 2026 EU AI Act timeline, …)"
              value={query}
              rows={5}
              onChange={(e) => setQuery(e.target.value)}
              onKeyDown={(e) => {
                if (e.key === "Enter" && (e.metaKey || e.ctrlKey)) {
                  e.preventDefault();
                  submit(query, maxSearches);
                }
              }}
            />
          </div>
          <div className="lg-ai-actions">
            <label
              style={{
                display: "inline-flex",
                alignItems: "center",
                gap: 6,
                fontSize: 12,
                color: "rgba(60, 60, 67, 0.7)",
              }}
            >
              Max searches:
              <select
                className="lg-ai-research-select"
                value={maxSearches}
                onChange={(e) => setMaxSearches(parseInt(e.target.value, 10))}
              >
                {MAX_SEARCH_OPTIONS.map((n) => (
                  <option key={n} value={n}>
                    {n}
                  </option>
                ))}
              </select>
            </label>
            <div style={{ flex: 1 }} />
            <button
              type="button"
              className="lg-ai-secondary"
              onMouseDown={(e) => e.preventDefault()}
              onClick={onClose}
            >
              Cancel
            </button>
            <button
              type="button"
              className="lg-ai-primary"
              disabled={query.trim().length === 0}
              onMouseDown={(e) => e.preventDefault()}
              onClick={() => submit(query, maxSearches)}
            >
              Start Research
            </button>
          </div>
        </>
      )}

      {state.kind === "loading" && (
        <div className="lg-ai-row">
          <div className="lg-ai-loader" aria-hidden="true">
            <span /><span /><span />
          </div>
          <div className="lg-ai-status">
            Researching… (this may take a minute)
          </div>
          <button
            type="button"
            className="lg-ai-secondary"
            onMouseDown={(e) => e.preventDefault()}
            onClick={cancelLoading}
          >
            Cancel
          </button>
        </div>
      )}

      {state.kind === "preview" && (
        <div className="lg-ai-preview">
          <div
            style={{
              fontSize: 11,
              color: "rgba(60, 60, 67, 0.7)",
              marginBottom: 2,
            }}
          >
            Research report ({state.report.length.toLocaleString()} chars)
          </div>
          <pre className="lg-ai-text lg-ai-research-text">{state.report}</pre>
          <div className="lg-ai-actions">
            <button
              type="button"
              className="lg-ai-secondary"
              onMouseDown={(e) => e.preventDefault()}
              onClick={() => copy(state.report)}
            >
              Copy
            </button>
            <div style={{ flex: 1 }} />
            <button
              type="button"
              className="lg-ai-secondary"
              onMouseDown={(e) => e.preventDefault()}
              onClick={discard}
            >
              Discard
            </button>
            <button
              type="button"
              className="lg-ai-primary"
              onMouseDown={(e) => e.preventDefault()}
              onClick={() => insert(state.report)}
            >
              Insert as new section
            </button>
          </div>
        </div>
      )}

      {state.kind === "error" && (
        <div className="lg-ai-preview">
          <div className="lg-ai-error">{state.message}</div>
          <div className="lg-ai-actions">
            {state.error === "missing-key" ? (
              <button
                type="button"
                className="lg-ai-primary"
                onMouseDown={(e) => e.preventDefault()}
                onClick={() => {
                  openSettings();
                  onClose();
                }}
              >
                Open Settings
              </button>
            ) : (
              <button
                type="button"
                className="lg-ai-secondary"
                onMouseDown={(e) => e.preventDefault()}
                onClick={() => submit(state.query, state.maxSearches)}
              >
                Retry
              </button>
            )}
            <div style={{ flex: 1 }} />
            <button
              type="button"
              className="lg-ai-secondary"
              onMouseDown={(e) => e.preventDefault()}
              onClick={onClose}
            >
              Close
            </button>
          </div>
        </div>
      )}
    </div>
  );
}

/**
 * Parses the markdown report and appends the resulting blocks after the
 * last block in the document. Never replaces existing content. If the doc
 * is empty (no blocks somehow), we fall back to `replaceBlocks` on the
 * empty document — BlockNote tolerates this and the report just becomes
 * the whole doc.
 */
function insertReportSection(editor: AnyEditor, report: string) {
  let blocks: unknown[];
  try {
    blocks = editor.tryParseMarkdownToBlocks(report) ?? [];
  } catch {
    blocks = [];
  }
  if (!Array.isArray(blocks) || blocks.length === 0) {
    // Fall through: treat the report as a single paragraph so something
    // ends up in the doc rather than nothing.
    blocks = [{ type: "paragraph", content: report }];
  }
  const doc = editor.document;
  if (Array.isArray(doc) && doc.length > 0) {
    editor.insertBlocks(blocks, doc[doc.length - 1], "after");
  } else {
    // Edge case: empty doc. Just replace.
    try {
      editor.replaceBlocks(editor.document, blocks);
    } catch {
      // Last-ditch: ignore so the popup at least closes cleanly.
    }
  }
}
