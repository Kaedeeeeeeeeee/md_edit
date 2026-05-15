import { useEffect, useMemo, useRef, useState } from "react";
import {
  sendAIRequestStream,
  openSettings,
  type AIChatMessage,
  type StreamHandle,
} from "./aiBridge";

// eslint-disable-next-line @typescript-eslint/no-explicit-any
type AnyEditor = any;

export interface AISelectionContext {
  from: number;
  to: number;
  selectedText: string;
  contextBefore: string;
  contextAfter: string;
  anchor: { left: number; top: number; bottom: number };
  /**
   * When set, the popup auto-fires this prompt on mount (skipping the input
   * step) — used by the macOS AI menu items that operate on the whole
   * document.
   */
  autoPrompt?: string;
}

export interface AIPromptPopupProps {
  editor: AnyEditor;
  context: AISelectionContext;
  onClose: () => void;
}

type ChatTurn = AIChatMessage;

type PopupState =
  | { kind: "input" }
  // `loading`: request fired, no deltas yet. Shown as the "Thinking…" spinner.
  | { kind: "loading"; prompt: string; history: ChatTurn[] }
  // `streaming`: first delta has arrived. Render `text` progressively. UI
  // shows the preview pane with a Stop button instead of Accept/Reject.
  | { kind: "streaming"; prompt: string; text: string; history: ChatTurn[] }
  | { kind: "preview"; prompt: string; text: string; history: ChatTurn[] }
  | {
      kind: "error";
      prompt: string;
      error: string;
      message: string;
      history: ChatTurn[];
    };

/**
 * Mirror of Swift's single-shot prompt template, built client-side so the
 * Swift bridge sees a single, consistent representation regardless of whether
 * the call is single-shot or multi-turn.
 */
function composeFirstUserMessage(
  prompt: string,
  selectedMarkdown: string,
  contextBefore: string,
  contextAfter: string,
): string {
  return `INSTRUCTION:
${prompt}

BEFORE:
${contextBefore}

SELECTED:
${selectedMarkdown}

AFTER:
${contextAfter}`;
}

/**
 * Floating AI prompt UI. Anchors to the current selection rect.
 *
 * Known P0 limitations (documented in plan):
 *  - Cancel during loading just closes locally; the URLSession keeps running
 *    in Swift and its response is discarded.
 *
 * Inline marks (bold/italic/code/strike/link) round-trip via a markdown
 * subset: the selection is serialized in EmbeddedEditor.captureSelectionContext
 * and the AI's reply is parsed back through buildInlineNodesFromBlock below.
 */
export function AIPromptPopup({
  editor,
  context,
  onClose,
}: AIPromptPopupProps) {
  const [state, setState] = useState<PopupState>({ kind: "input" });
  const [prompt, setPrompt] = useState("");
  const [refineText, setRefineText] = useState("");
  const inputRef = useRef<HTMLInputElement | null>(null);
  const refineInputRef = useRef<HTMLInputElement | null>(null);
  const popupRef = useRef<HTMLDivElement | null>(null);
  // Pinned to the request that's currently in-flight, so late stream events
  // arriving after Cancel/Reset are ignored.
  const activeRequestRef = useRef(0);
  // Handle to the currently-streaming Swift request, so Stop can abort it.
  // Stored in a ref because the abort path doesn't need to drive re-renders.
  const streamHandleRef = useRef<StreamHandle | null>(null);

  // Abort any in-flight stream when the popup unmounts. Without this, the
  // Swift task keeps running and posts deltas at a JS listener that's gone.
  useEffect(() => {
    return () => {
      streamHandleRef.current?.abort();
      streamHandleRef.current = null;
    };
  }, []);

  useEffect(() => {
    if (context.autoPrompt) {
      submit(context.autoPrompt);
    } else {
      inputRef.current?.focus();
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  useEffect(() => {
    function onKey(e: KeyboardEvent) {
      if (e.key === "Escape") {
        onClose();
      }
    }
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [onClose]);

  // Click-outside-to-dismiss. Mirrors the formatting toolbar's behavior so
  // the popup doesn't get stranded when the user clicks elsewhere. Uses
  // mousedown (not click) so it fires before any potential native focus
  // changes — and runs in the capture phase so it sees the event even if a
  // child stops propagation.
  useEffect(() => {
    function onMouseDown(e: MouseEvent) {
      const target = e.target as Node | null;
      const root = popupRef.current;
      if (!root || !target) return;
      if (root.contains(target)) return;
      onClose();
    }
    document.addEventListener("mousedown", onMouseDown, true);
    return () => document.removeEventListener("mousedown", onMouseDown, true);
  }, [onClose]);

  const style = useMemo<React.CSSProperties>(() => {
    // Strategy: if the popup at desiredLeft would extend past the viewport
    // right edge, switch to anchoring from the right (`right: gutter`)
    // instead of left. This guarantees the popup fits regardless of its
    // actual rendered width (Skills strip / streaming text can make the
    // popup wider than the `max-width` CSS would suggest in edge cases).
    const popupWidth = 480;
    const gutter = 12;
    const viewportWidth = window.innerWidth;
    const desiredLeft = context.anchor.left;
    const top = context.anchor.bottom + 6;

    if (desiredLeft + popupWidth > viewportWidth - gutter) {
      return {
        position: "fixed",
        right: gutter,
        top,
        zIndex: 9999,
        maxWidth: `calc(100vw - ${gutter * 2}px)`,
      };
    }
    return {
      position: "fixed",
      left: Math.max(gutter, desiredLeft),
      top,
      zIndex: 9999,
      maxWidth: `calc(100vw - ${gutter * 2}px)`,
    };
  }, [context.anchor.left, context.anchor.bottom]);

  // Common streaming runner. Sets up loading state, fires the stream, and
  // funnels deltas/end events into preview/error transitions. Returns nothing
  // — the stream is fire-and-forget; cancellation is via streamHandleRef.
  //
  // `outboundHistory` is what we send on the wire (user turn is its last
  // entry). On success we'll append the assistant turn to form the
  // `nextHistory` shown in preview.
  function runStream(args: {
    promptForUI: string;
    outboundHistory: ChatTurn[];
    onSuccessSettled?: () => void;
  }) {
    const { promptForUI, outboundHistory, onSuccessSettled } = args;
    const requestNum = ++activeRequestRef.current;
    setState({ kind: "loading", prompt: promptForUI, history: outboundHistory });

    // Abort any earlier stream that hasn't terminated yet — clicking Retry
    // mid-stream, for example.
    streamHandleRef.current?.abort();

    const handle = sendAIRequestStream(
      {
        messages: outboundHistory,
        selectedMarkdown: context.selectedText,
        contextBefore: context.contextBefore,
        contextAfter: context.contextAfter,
      },
      (chunk) => {
        if (requestNum !== activeRequestRef.current) return;
        setState((prev) => {
          if (prev.kind === "loading" || prev.kind === "streaming") {
            const acc = prev.kind === "streaming" ? prev.text + chunk : chunk;
            return {
              kind: "streaming",
              prompt: promptForUI,
              text: acc,
              history: outboundHistory,
            };
          }
          return prev;
        });
      },
      (result) => {
        if (requestNum !== activeRequestRef.current) return;
        streamHandleRef.current = null;
        if (result.ok) {
          setState((prev) => {
            // Successful completion: capture whatever text we accumulated
            // during streaming. If we never streamed (zero-delta success —
            // unusual but possible), fall back to empty.
            const finalText =
              prev.kind === "streaming"
                ? prev.text
                : prev.kind === "loading"
                  ? ""
                  : null;
            if (finalText === null) return prev;
            const nextHistory: ChatTurn[] = [
              ...outboundHistory,
              { role: "assistant", content: finalText },
            ];
            return {
              kind: "preview",
              prompt: promptForUI,
              text: finalText,
              history: nextHistory,
            };
          });
          onSuccessSettled?.();
        } else if (result.error === "cancelled") {
          // Abort initiated by Stop or unmount — reset back to input so the
          // user can try a different prompt. Don't surface as an error.
          setState({ kind: "input" });
        } else {
          setState({
            kind: "error",
            prompt: promptForUI,
            error: result.error,
            message: result.message,
            history: outboundHistory,
          });
        }
      },
    );
    streamHandleRef.current = handle;
  }

  // First-turn submit: build the BEFORE/SELECTED/AFTER-wrapped user message
  // client-side and send it as a single-item messages array. We intentionally
  // stop relying on Swift's old single-shot template path, so the on-wire
  // representation matches what we'll send on subsequent refine turns.
  function submit(p: string) {
    const trimmed = p.trim();
    if (!trimmed) return;
    const composedUserMsg = composeFirstUserMessage(
      trimmed,
      context.selectedText,
      context.contextBefore,
      context.contextAfter,
    );
    const newHistory: ChatTurn[] = [{ role: "user", content: composedUserMsg }];
    runStream({ promptForUI: trimmed, outboundHistory: newHistory });
  }

  // Follow-up turn: takes the existing conversation history (which already
  // includes the BEFORE/SELECTED/AFTER context inside the first user message),
  // appends the user's refinement prompt, and sends the whole array.
  function refine(followupPrompt: string, baseHistory: ChatTurn[]) {
    const trimmed = followupPrompt.trim();
    if (!trimmed) return;
    const newHistory: ChatTurn[] = [
      ...baseHistory,
      { role: "user", content: trimmed },
    ];
    runStream({
      promptForUI: trimmed,
      outboundHistory: newHistory,
      onSuccessSettled: () => setRefineText(""),
    });
  }

  // Re-runs the latest user turn (either the initial composed message or the
  // most recent refinement) against the prior history. Used by the Retry
  // buttons in preview/error states.
  function retryLatest(history: ChatTurn[]) {
    // Find the last user turn and re-send the conversation up to and
    // including it. For the first-turn case this is just [composed user].
    const lastUserIdx = (() => {
      for (let i = history.length - 1; i >= 0; i--) {
        if (history[i].role === "user") return i;
      }
      return -1;
    })();
    if (lastUserIdx < 0) return;
    const replayHistory = history.slice(0, lastUserIdx + 1);
    const lastPrompt = replayHistory[replayHistory.length - 1].content;
    runStream({ promptForUI: lastPrompt, outboundHistory: replayHistory });
  }

  // Stop button while streaming: aborts the URLSession on the Swift side.
  // The end callback fires with `cancelled` and resets state to `input`.
  function stop() {
    streamHandleRef.current?.abort();
    streamHandleRef.current = null;
    activeRequestRef.current++;
    setState({ kind: "input" });
  }

  function reset() {
    streamHandleRef.current?.abort();
    streamHandleRef.current = null;
    activeRequestRef.current++; // invalidate any in-flight response
    setPrompt("");
    setRefineText("");
    setState({ kind: "input" });
  }

  function accept(text: string) {
    applyReplacement(editor, context, text);
    onClose();
  }

  return (
    <div ref={popupRef} className="lg-ai-popup" style={style} role="dialog" aria-label="Ask AI">
      {state.kind === "input" && (
        <>
          <div className="lg-ai-row">
            <input
              ref={inputRef}
              className="lg-ai-input"
              type="text"
              placeholder="Tell AI what to do…"
              value={prompt}
              onChange={(e) => setPrompt(e.target.value)}
              onKeyDown={(e) => {
                if (e.key === "Enter" && !e.shiftKey) {
                  e.preventDefault();
                  submit(prompt);
                }
              }}
            />
            <button
              type="button"
              className="lg-ai-primary"
              disabled={prompt.trim().length === 0}
              onMouseDown={(e) => e.preventDefault()}
              onClick={() => submit(prompt)}
            >
              ↵
            </button>
          </div>
        </>
      )}

      {state.kind === "loading" && (
        <div className="lg-ai-row">
          <div className="lg-ai-loader">
            <span /><span /><span />
          </div>
          <div className="lg-ai-status">Thinking…</div>
          <button
            type="button"
            className="lg-ai-secondary"
            onMouseDown={(e) => e.preventDefault()}
            onClick={stop}
          >
            Stop
          </button>
        </div>
      )}

      {state.kind === "streaming" && (
        <div className="lg-ai-preview">
          <pre className="lg-ai-text">{state.text}</pre>
          <div className="lg-ai-actions">
            <div className="lg-ai-loader" aria-hidden="true">
              <span /><span /><span />
            </div>
            <div className="lg-ai-status">Generating…</div>
            <div style={{ flex: 1 }} />
            <button
              type="button"
              className="lg-ai-secondary"
              onMouseDown={(e) => e.preventDefault()}
              onClick={stop}
            >
              Stop
            </button>
          </div>
        </div>
      )}

      {state.kind === "preview" && (
        <div className="lg-ai-preview">
          <pre className="lg-ai-text">{state.text}</pre>
          <div className="lg-ai-actions">
            <button
              type="button"
              className="lg-ai-secondary"
              onMouseDown={(e) => e.preventDefault()}
              onClick={() => retryLatest(state.history)}
            >
              Retry
            </button>
            <div style={{ flex: 1 }} />
            <button
              type="button"
              className="lg-ai-secondary"
              onMouseDown={(e) => e.preventDefault()}
              onClick={onClose}
            >
              Reject
            </button>
            <button
              type="button"
              className="lg-ai-primary"
              onMouseDown={(e) => e.preventDefault()}
              onClick={() => accept(state.text)}
            >
              Accept
            </button>
          </div>
          <div className="lg-ai-divider" />
          <div className="lg-ai-row">
            <input
              ref={refineInputRef}
              className="lg-ai-input"
              type="text"
              placeholder="Make changes…"
              value={refineText}
              onChange={(e) => setRefineText(e.target.value)}
              onKeyDown={(e) => {
                if (e.key === "Enter" && !e.shiftKey) {
                  e.preventDefault();
                  refine(refineText, state.history);
                }
              }}
            />
            <button
              type="button"
              className="lg-ai-secondary"
              disabled={refineText.trim().length === 0}
              onMouseDown={(e) => e.preventDefault()}
              onClick={() => refine(refineText, state.history)}
            >
              ↵
            </button>
            <button
              type="button"
              className="lg-ai-secondary"
              onMouseDown={(e) => e.preventDefault()}
              onClick={reset}
            >
              Reset
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
                onClick={() => retryLatest(state.history)}
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
 * Builds an array of ProseMirror text nodes (with marks) from a parsed
 * BlockNote paragraph block. Returns null if the block isn't a paragraph
 * with usable inline content.
 *
 * BlockNote 0.50 represents a paragraph's inline content as:
 *   { type: "text"; text: string; styles?: { bold?, italic?, strike?, code?, underline?, ... } }
 *   | { type: "link"; href: string; content: Array<{ type: "text"; ... }> }
 *
 * We translate that to ProseMirror text nodes whose marks correspond to the
 * BlockNote default style schema. Mark type names in BlockNote's TipTap
 * registration match the style keys 1:1 (`bold`, `italic`, `strike`, `code`,
 * `underline`, plus `link` for the link mark).
 */
// eslint-disable-next-line @typescript-eslint/no-explicit-any
function buildInlineNodesFromBlock(block: any, schema: any): any[] | null {
  if (!block || block.type !== "paragraph") return null;
  const inlineContent = block.content;
  if (!Array.isArray(inlineContent)) return null;

  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const nodes: any[] = [];
  for (const item of inlineContent) {
    if (item?.type === "text" && typeof item.text === "string") {
      if (item.text.length === 0) continue;
      const marks = stylesToMarks(item.styles ?? {}, schema);
      nodes.push(schema.text(item.text, marks));
    } else if (item?.type === "link") {
      const href = typeof item.href === "string" ? item.href : "";
      const linkMarkType = schema.marks.link;
      const inner = Array.isArray(item.content) ? item.content : [];
      for (const inn of inner) {
        if (inn?.type !== "text" || typeof inn.text !== "string") continue;
        if (inn.text.length === 0) continue;
        const baseMarks = stylesToMarks(inn.styles ?? {}, schema);
        const marks = linkMarkType
          ? [linkMarkType.create({ href }), ...baseMarks]
          : baseMarks;
        nodes.push(schema.text(inn.text, marks));
      }
    }
    // Unknown inline content kinds (custom inline blocks, mentions, etc.)
    // are skipped rather than corrupting the splice. The block path will
    // pick them up via replaceBlocks if the structure is rich enough.
  }
  return nodes.length > 0 ? nodes : null;
}

/**
 * Translates a BlockNote `styles` object to an array of ProseMirror marks.
 * Unknown style keys (or those whose mark type isn't registered in the
 * schema) are silently dropped so we don't crash on schema drift.
 */
// eslint-disable-next-line @typescript-eslint/no-explicit-any
function stylesToMarks(styles: Record<string, unknown>, schema: any): any[] {
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const marks: any[] = [];
  const push = (name: string) => {
    const type = schema.marks?.[name];
    if (type) marks.push(type.create());
  };
  if (styles.bold) push("bold");
  if (styles.italic) push("italic");
  if (styles.strike) push("strike");
  if (styles.code) push("code");
  if (styles.underline) push("underline");
  return marks;
}

/**
 * Applies the AI-generated text to the editor at the captured selection range.
 *
 * Hybrid strategy:
 *   1. Parse the AI's markdown reply into BlockNote blocks via the high-level
 *      `tryParseMarkdownToBlocks` API. This handles headings, lists, code
 *      blocks, hard breaks, etc. naturally.
 *   2. Choose the splice path based on what the AI returned and what the user
 *      had selected:
 *        - Inline path (`tr.replaceWith` with a fragment of text nodes that
 *          carry marks): when the AI gave back a single paragraph AND the
 *          user's original selection was a sub-block range (both endpoints
 *          inside one block). This preserves the rest of the paragraph
 *          instead of replacing the whole block, AND keeps any bold/italic/
 *          code/strike/link marks the AI returned.
 *        - Cursor inline insert (`tr.replaceWith` at cursor): selection was
 *          empty and the AI gave back a single paragraph — splice inline.
 *        - Block path (`editor.replaceBlocks` / `insertBlocks`): everything
 *          else (multi-block AI reply, cross-block selection, or multi-block
 *          insert at empty cursor).
 *
 * The captured `from`/`to` positions stay valid because the document is
 * locked (isEditable=false) while the popup is open; the slash menu's
 * onItemClick captures positions and we don't otherwise mutate the doc in
 * between.
 */
function applyReplacement(
  editor: AnyEditor,
  context: AISelectionContext,
  text: string,
) {
  const view = editor.prosemirrorView;
  if (!view) return;
  const { state, dispatch } = view;
  const schema = state.schema;
  const { from, to } = context;

  const trimmed = text.replace(/^\s+|\s+$/g, "");

  // Parse the AI reply into BlockNote blocks. Synchronous — returns Block[].
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const newBlocks = editor.tryParseMarkdownToBlocks(trimmed) as any[];

  // Whole-document path (macOS AI menu): replace every block in the doc with
  // the AI's output, regardless of how PM `from`/`to` map to BlockNote blocks.
  const docSize = state.doc.content.size;
  if (from === 0 && to === docSize) {
    const safeBlocks =
      newBlocks.length > 0 ? newBlocks : [{ type: "paragraph" }];
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    editor.replaceBlocks(editor.document, safeBlocks as any);
    view.focus();
    return;
  }

  const isSingleParagraph =
    newBlocks.length === 1 && newBlocks[0]?.type === "paragraph";

  // Extract the plain-text inline content of a single-paragraph block. Used
  // for the inline replacement paths so we don't replace the whole block
  // when the AI only rewrote a span of text.
  function singleParagraphText(): string {
    const content = newBlocks[0]?.content;
    if (typeof content === "string") return content;
    if (Array.isArray(content)) {
      return content
        .map((c) =>
          typeof c === "object" && c && "text" in c
            ? String((c as { text: unknown }).text)
            : "",
        )
        .join("");
    }
    return trimmed;
  }

  if (from === to) {
    // Cursor-only: no selection. If single paragraph, insert inline at cursor
    // (preserve old behavior); otherwise splice block(s) after the current
    // block via the high-level API.
    if (isSingleParagraph) {
      if (trimmed.length === 0) {
        // Nothing to insert.
      } else {
        // Prefer the marks-preserving path; fall back to plain text if the
        // parsed block didn't yield usable inline content (e.g. exotic
        // inline elements we don't translate).
        const inlineNodes = buildInlineNodesFromBlock(newBlocks[0], schema);
        const tr = state.tr;
        if (inlineNodes && inlineNodes.length > 0) {
          tr.replaceWith(from, from, inlineNodes);
        } else {
          tr.insertText(singleParagraphText(), from);
        }
        dispatch(tr);
      }
    } else if (newBlocks.length > 0) {
      const cursor = editor.getTextCursorPosition();
      if (cursor?.block) {
        editor.insertBlocks(newBlocks, cursor.block, "after");
      }
    }
  } else {
    // The user had a real selection. Determine whether both endpoints live
    // in the same block (sub-block range) so we can preserve the surrounding
    // text when the AI returned a single paragraph.
    const $from = state.doc.resolve(from);
    const $to = state.doc.resolve(to);
    const isSubBlockRange = $from.sameParent($to);

    if (isSingleParagraph && isSubBlockRange) {
      // Inline path: replace just the selected range inside the block with
      // a fragment of inline text nodes carrying any bold/italic/code/strike/
      // link marks the AI included. Falls back to a plain text node if no
      // inline content could be built.
      const tr = state.tr;
      const inlineNodes = buildInlineNodesFromBlock(newBlocks[0], schema);
      if (inlineNodes && inlineNodes.length > 0) {
        tr.replaceWith(from, to, inlineNodes);
      } else {
        const inline = singleParagraphText();
        if (inline.length === 0) {
          tr.delete(from, to);
        } else {
          tr.replaceWith(from, to, schema.text(inline));
        }
      }
      dispatch(tr);
    } else {
      // Block path: replace the spanned blocks with the parsed AI output.
      const selection = editor.getSelection();
      const targetBlocks =
        selection?.blocks?.length
          ? selection.blocks
          : [editor.getTextCursorPosition().block];
      if (newBlocks.length === 0) {
        // AI returned nothing — replace with an empty paragraph so we don't
        // leave the doc in an invalid state.
        editor.replaceBlocks(targetBlocks, [{ type: "paragraph" }]);
      } else {
        editor.replaceBlocks(targetBlocks, newBlocks);
      }
    }
  }

  view.focus();
}
