import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import {
  useCreateBlockNote,
  SuggestionMenuController,
  FormattingToolbarController,
  SideMenuController,
  getDefaultReactSlashMenuItems,
  type DefaultReactSuggestionItem,
} from "@blocknote/react";
import { BlockNoteView } from "@blocknote/mantine";
import {
  BlockNoteSchema,
  defaultBlockSpecs,
  filterSuggestionItems,
  insertOrUpdateBlockForSlashMenu,
} from "@blocknote/core";
import { en, zh } from "@blocknote/core/locales";
import { MathBlock } from "./MathBlock";
import { LiquidGlassSlashMenu } from "./LiquidGlassSlashMenu";
import { LiquidGlassFormattingToolbar } from "./LiquidGlassFormattingToolbar";
import { CursorHalo } from "./CursorHalo";
import { getDict, type AppLocale } from "./dict";
import { AIPromptPopup, type AISelectionContext } from "./ai/AIPromptPopup";
import { AIResearchPopup } from "./ai/AIResearchPopup";
import { AILiquidGlassSideMenu } from "./ai/AILiquidGlassSideMenu";
import { installAIBridge, type AIResponse } from "./ai/aiBridge";
import {
  installResearchBridge,
  type AIResearchResponse,
  type AIProviderProbe,
} from "./ai/researchBridge";
import { installSpaceTrigger } from "./ai/spaceTriggerPlugin";
import { inlineFragmentToMarkdown } from "./ai/inlineMarkdown";
import { installEditorAgentBridge } from "./agent/editorBridge";
import {
  SourceMarkdownEditor,
  type SourceMarkdownEditorHandle,
} from "./SourceMarkdownEditor";
import "@blocknote/mantine/style.css";

declare global {
  interface Window {
    editorBridge?: {
      loadMarkdown: (markdown: string) => void;
      resolveUpload: (requestId: string, url: string) => void;
      rejectUpload: (requestId: string, message: string) => void;
      setLocale?: (code: string) => void;
      aiResponse?: (requestId: string, payload: AIResponse) => void;
      aiStreamChunk?: (requestId: string, delta: string) => void;
      aiStreamEnd?: (
        requestId: string,
        payload: { ok: true } | { ok: false; error: string; message: string },
      ) => void;
      aiResearchResponse?: (requestId: string, payload: AIResearchResponse) => void;
      aiProviderProbeResponse?: (requestId: string, payload: AIProviderProbe) => void;
      runPageAction?: (action: string) => void;
      openResearch?: () => void;
      // Called by the native SwiftUI AI Assistant panel via evaluateJavaScript.
      // aiGetDocumentMarkdown returns synchronously (its value is captured by
      // evaluateJavaScript's completion handler); the other two are
      // fire-and-forget.
      aiGetDocumentMarkdown?: () => string;
      aiInsertAtCursor?: (markdown: string) => void;
      aiReplaceSelection?: (markdown: string) => void;
    };
    webkit?: {
      messageHandlers?: {
        editor?: {
          postMessage: (message: unknown) => void;
        };
      };
    };
  }
}

function postToHost(message: unknown) {
  window.webkit?.messageHandlers?.editor?.postMessage(message);
}

// ---- Image upload bridge --------------------------------------------------
//
// BlockNote calls `uploadFile(file)` whenever the user pastes or drops an
// image.  We ship the bytes over to Swift as base64, Swift writes them to
// `<workspace>/attachments/<uuid>.<ext>` and calls back into the bridge with
// the relative path.  Returning a relative URL means the markdown export is
// `![](attachments/xxx.png)` — readable by GitHub, VS Code, Typora — and
// the EditorSchemeHandler resolves the same path back to disk when the
// editor renders the image.

type PendingUpload = {
  resolve: (url: string) => void;
  reject: (err: Error) => void;
};
const pendingUploads = new Map<string, PendingUpload>();
let uploadCounter = 0;

function readFileAsBase64(file: File): Promise<{ base64: string; mime: string }> {
  return new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.onload = () => {
      const dataURL = String(reader.result ?? "");
      const match = /^data:([^;]+);base64,(.+)$/.exec(dataURL);
      if (!match) {
        reject(new Error("Expected a base64 data URL from FileReader."));
        return;
      }
      resolve({ mime: match[1], base64: match[2] });
    };
    reader.onerror = () => reject(reader.error ?? new Error("FileReader failed"));
    reader.readAsDataURL(file);
  });
}

function extFromMime(mime: string): string {
  switch (mime) {
    case "image/png": return "png";
    case "image/jpeg": return "jpg";
    case "image/gif": return "gif";
    case "image/webp": return "webp";
    case "image/svg+xml": return "svg";
    case "image/heic": return "heic";
    case "image/heif": return "heif";
    case "image/bmp": return "bmp";
    case "image/tiff": return "tiff";
  }
  // Fallback: trim "image/" prefix, drop everything non-alphanumeric.
  const slash = mime.indexOf("/");
  const tail = slash >= 0 ? mime.slice(slash + 1) : mime;
  const cleaned = tail.replace(/[^a-z0-9]/gi, "").toLowerCase();
  return cleaned.length > 0 && cleaned.length <= 6 ? cleaned : "png";
}

async function uploadFile(file: File): Promise<string> {
  if (!file.type.startsWith("image/")) {
    throw new Error("Only image files can be inserted right now.");
  }
  const { base64, mime } = await readFileAsBase64(file);
  const ext = extFromMime(file.type || mime);
  const requestId = `up-${++uploadCounter}-${Date.now().toString(36)}`;
  return new Promise<string>((resolve, reject) => {
    pendingUploads.set(requestId, { resolve, reject });
    postToHost({ type: "saveImage", requestId, base64, mime, ext });
  });
}

// ---- Schema ---------------------------------------------------------------

const schema = BlockNoteSchema.create({
  blockSpecs: {
    ...defaultBlockSpecs,
    math: MathBlock(),
  },
});

// Use BlockNote's own helpers as `any` boundaries — its generic types are
// deep and getting them perfectly threaded through custom blocks costs more
// signal than it adds.  We keep our own logic strongly typed at the seams.
// eslint-disable-next-line @typescript-eslint/no-explicit-any
type Editor = any;
type AnyBlock = { type: string; props?: Record<string, unknown>; content?: unknown };

// ---- Markdown ↔ math-block bridging ---------------------------------------
//
// BlockNote 0.50's markdown converter doesn't know about our custom math
// block, so we splice the math content in and out around the standard
// markdown round-trip:
//
//   import path: $$ ... $$ → placeholder string → tryParseMarkdownToBlocks
//                → replace placeholder paragraphs with math blocks
//   export path: math block → paragraph containing $$ ... $$
//                → blocksToMarkdownLossy → string

const MATH_PLACEHOLDER_PREFIX = "MARKTEXTNEXT_MATH_BLOCK_";
const MATH_PLACEHOLDER_RE = new RegExp(`^${MATH_PLACEHOLDER_PREFIX}(\\d+)$`);

function extractMathBlocks(markdown: string): { stripped: string; formulas: string[] } {
  const formulas: string[] = [];
  const stripped = markdown.replace(/\$\$\s*([\s\S]*?)\s*\$\$/g, (_, latex: string) => {
    const i = formulas.length;
    formulas.push(latex.trim());
    return `${MATH_PLACEHOLDER_PREFIX}${i}`;
  });
  return { stripped, formulas };
}

function readParagraphText(block: AnyBlock): string {
  const content = block.content;
  if (typeof content === "string") return content;
  if (Array.isArray(content)) {
    return content
      .map((c) => (typeof c === "object" && c && "text" in c ? String((c as { text: unknown }).text) : ""))
      .join("");
  }
  return "";
}

function rebuildMathBlocks(blocks: AnyBlock[], formulas: string[]): AnyBlock[] {
  return blocks.map((b) => {
    if (b.type === "paragraph") {
      const text = readParagraphText(b);
      const m = MATH_PLACEHOLDER_RE.exec(text.trim());
      if (m) {
        const idx = parseInt(m[1], 10);
        const latex = formulas[idx] ?? "";
        return { type: "math", props: { latex } };
      }
    }
    return b;
  });
}

function blocksWithMathInlined(blocks: AnyBlock[]): AnyBlock[] {
  return blocks.map((b) => {
    if (b.type === "math") {
      const latex = String(b.props?.latex ?? "").trim();
      return { type: "paragraph", content: `$$\n${latex}\n$$` };
    }
    return b;
  });
}

// ---- Auto-focus on document open -------------------------------------------

/**
 * Returns true when a BlockNote block contains no visible text content.
 * Used by `placeCursorAtIdealStart` to decide whether the document already
 * has a "blank trailing line" we can drop the caret into, or we need to
 * synthesize one.
 */
function isBlockEmpty(block: AnyBlock): boolean {
  if (!block) return true;
  const content = block.content;
  if (content == null) return true;
  if (typeof content === "string") return content.trim().length === 0;
  if (Array.isArray(content)) {
    if (content.length === 0) return true;
    return content.every((c) => {
      if (c && typeof c === "object" && "text" in c) {
        const t = (c as { text?: unknown }).text;
        return typeof t === "string" ? t.length === 0 : true;
      }
      return false;
    });
  }
  return false;
}

/**
 * Places the cursor in the "natural starting spot" after a document loads:
 * an empty paragraph below all content (synthesised if missing), or the
 * first paragraph if the doc was already empty. Focuses the editor so the
 * breathing halo is immediately visible without a mouse click.
 */
function placeCursorAtIdealStart(editor: Editor) {
  const doc = editor.document as AnyBlock[];
  if (!doc || doc.length === 0) {
    editor.prosemirrorView?.focus?.();
    return;
  }

  const last = doc[doc.length - 1];

  if (!isBlockEmpty(last)) {
    // Append an empty paragraph below the existing content so the caret
    // sits on a fresh line — matches the user's mental model of "click in
    // the editor to start writing below what's there".
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    editor.insertBlocks([{ type: "paragraph" }] as any, last as any, "after");
    const refreshed = editor.document as AnyBlock[];
    const newLast = refreshed[refreshed.length - 1];
    editor.setTextCursorPosition(newLast, "start");
  } else {
    editor.setTextCursorPosition(last, "start");
  }
  editor.prosemirrorView?.focus?.();
}

// ---- Slash menu helpers ----------------------------------------------------

function buildSlashItems(
  editor: Editor,
  query: string,
  locale: AppLocale,
  onAskAI: () => void,
): DefaultReactSuggestionItem[] {
  const dict = getDict(locale);
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const defaults = getDefaultReactSlashMenuItems(editor as any);
  const custom: DefaultReactSuggestionItem[] = [
    {
      title: dict.mathTitle,
      subtext: dict.mathSubtext,
      onItemClick: () => {
        // eslint-disable-next-line @typescript-eslint/no-explicit-any
        insertOrUpdateBlockForSlashMenu(editor as any, {
          type: "math",
          props: { latex: "x^2 + y^2 = z^2" },
          // eslint-disable-next-line @typescript-eslint/no-explicit-any
        } as any);
      },
      aliases: ["math", "latex", "equation", "tex", "formula", "公式", "数学"],
      group: dict.groupAdvanced,
      icon: <span style={{ fontFamily: "serif", fontWeight: 700 }}>∑</span>,
    },
  ];
  // "Ask AI" goes at the END of the items array so:
  //   - selectedIndex defaults to 0 = the first regular item (Heading 1) →
  //     pressing Enter on a freshly opened menu still inserts a heading.
  //   - Pressing Up at index 0 wraps to the last index = AI, so keyboard
  //     navigation reaches AI from the top, matching the user expectation
  //     when arrowing upward.
  // Visually, <LiquidGlassSlashMenu> pulls the AI item out of the list and
  // renders it as a pinned chip at the very top — so the "AI at the top"
  // UX is preserved while logical index stays at the end.
  const aiItem: DefaultReactSuggestionItem = {
    title: dict.aiTitle,
    subtext: dict.aiSubtext,
    onItemClick: () => onAskAI(),
    aliases: ["ai", "ask", "rewrite", "help", "AI", "助手", "改写"],
    group: dict.groupAdvanced,
  };
  return filterSuggestionItems([...defaults, ...custom, aiItem], query);
}

const CONTEXT_WINDOW = 500;

/**
 * Captures the current ProseMirror selection (or cursor position) plus
 * surrounding context. Returns null if the editor isn't ready.
 *
 * Position semantics: `from`/`to` are ProseMirror doc positions. When the
 * slash menu is invoked, the trigger `/` and any typed query have already been
 * inserted at the cursor — we strip those by walking back one character past
 * the trigger before the popup opens. (See `openAIPopupFromSlash` below.)
 *
 * The selected range is serialized to a small subset of markdown so inline
 * marks (bold/italic/code/strike/link) survive the AI round-trip. The
 * surrounding before/after context stays plain text — it's only there to
 * help the model understand context, not to be inserted back.
 */
function captureSelectionContext(editor: Editor): AISelectionContext | null {
  const view = editor.prosemirrorView;
  if (!view) return null;
  const { state } = view;
  const { from, to } = state.selection;
  let selectedText = "";
  if (from !== to) {
    const slice = state.doc.slice(from, to);
    selectedText = inlineFragmentToMarkdown(slice);
  }
  const beforeStart = Math.max(0, from - CONTEXT_WINDOW);
  const afterEnd = Math.min(state.doc.content.size, to + CONTEXT_WINDOW);
  const contextBefore = state.doc.textBetween(beforeStart, from, "\n");
  const contextAfter = state.doc.textBetween(to, afterEnd, "\n");

  // Anchor coordinates: use the selection's start position so the popup hugs
  // the left edge of the highlight. coordsAtPos returns viewport coords,
  // which is what fixed-positioned popups need.
  const coords = view.coordsAtPos(from);
  return {
    from,
    to,
    selectedText,
    contextBefore,
    contextAfter,
    anchor: { left: coords.left, top: coords.top, bottom: coords.bottom },
  };
}

/**
 * Captures context for the WHOLE block at `block` (drag-handle ✨ Ask AI flow).
 *
 * BlockNote's PM doc layout:
 *   doc
 *     blockGroup           ← top-level container
 *       blockContainer     ← wrapper carrying attrs.id (the bnBlock group)
 *         <inline-content> ← the actual content node (paragraph/heading/etc)
 *
 * We walk descendants of `doc.firstChild` (the blockGroup), matching the
 * blockContainer by its `attrs.id`. We use the inline-content child's range
 * for selectedText capture so we don't include child blockGroups (nested
 * blocks) — but we use the whole blockContainer's range for the visual
 * anchor and so the AI's reply replaces the whole block via Accept's
 * replaceBlocks path.
 *
 * Returns null if the block can't be located (e.g. the editor view isn't
 * mounted yet).
 */
// eslint-disable-next-line @typescript-eslint/no-explicit-any
function captureBlockContext(
  editor: Editor,
  block: any, // BlockNote Block — opaque at this boundary, we only need .id
): AISelectionContext | null {
  const view = editor.prosemirrorView;
  if (!view) return null;
  const { state } = view;
  const blockId: string | undefined = block?.id;
  if (!blockId) return null;

  let containerPos: { from: number; to: number } | null = null;
  // doc.firstChild is the blockGroup; bnBlock-group nodes (blockContainer)
  // live below it. Walk and match attrs.id.
  const root = state.doc.firstChild;
  if (!root) return null;
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  root.descendants((node: any, pos: number) => {
    if (containerPos !== null) return false;
    if (
      node.type?.spec?.group?.split?.(" ").includes("bnBlock") &&
      node.attrs?.id === blockId
    ) {
      // pos is relative to root; +1 because root is doc.firstChild and we
      // need absolute doc positions. nodeSize includes the open/close tokens.
      const absStart = pos + 1;
      containerPos = { from: absStart, to: absStart + node.nodeSize };
      return false;
    }
    return true;
  });

  if (!containerPos) return null;
  const { from, to } = containerPos as { from: number; to: number };

  const docSize = state.doc.content.size;
  const safeFrom = Math.max(0, Math.min(from, docSize));
  const safeTo = Math.max(safeFrom, Math.min(to, docSize));

  // Plain-text content of the block, stripping nested block separators.
  const selectedText = state.doc.textBetween(safeFrom, safeTo, "\n");
  const beforeStart = Math.max(0, safeFrom - CONTEXT_WINDOW);
  const afterEnd = Math.min(docSize, safeTo + CONTEXT_WINDOW);
  const contextBefore = state.doc.textBetween(beforeStart, safeFrom, "\n");
  const contextAfter = state.doc.textBetween(safeTo, afterEnd, "\n");

  // Anchor at the block's top-left for popup positioning. coordsAtPos at
  // the block's start gives us a usable rect.
  const coords = view.coordsAtPos(safeFrom);
  return {
    from: safeFrom,
    to: safeTo,
    selectedText,
    contextBefore,
    contextAfter,
    anchor: { left: coords.left, top: coords.top, bottom: coords.bottom },
  };
}

/**
 * Captures context for the WHOLE document (used by the macOS AI menu items
 * Summarize Page / Translate Page…). Returns an AISelectionContext that spans
 * the entire PM doc and carries an `autoPrompt` so the popup auto-fires
 * without waiting for the user to type.
 */
function captureWholeDocContext(
  editor: Editor,
  action: string,
): (AISelectionContext & { autoPrompt?: string }) | null {
  const view = editor.prosemirrorView;
  if (!view) return null;
  // Prefer BlockNote's lossy markdown converter so structure (headings, lists,
  // code blocks) round-trips faithfully into the AI prompt.
  const docMarkdown: string = editor.blocksToMarkdownLossy
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    ? editor.blocksToMarkdownLossy(editor.document as any)
    : view.state.doc.textBetween(0, view.state.doc.content.size, "\n");

  // No meaningful anchor for a whole-doc action; pin near top-center of the
  // viewport.
  const viewportWidth = window.innerWidth;
  const anchor = { left: viewportWidth / 2 - 240, top: 80, bottom: 80 };

  const autoPrompt =
    action === "summarize"
      ? "Summarize this document concisely. Preserve the most important points and structure."
      : action === "translate"
      ? "Translate this document to English (or another language the user just asked for). Preserve all formatting."
      : "Improve this document.";

  return {
    from: 0,
    to: view.state.doc.content.size,
    selectedText: docMarkdown,
    contextBefore: "",
    contextAfter: "",
    anchor,
    autoPrompt,
  };
}

// ---- Component -------------------------------------------------------------

export interface EmbeddedEditorProps {
  locale: AppLocale;
}

type EditorMode = "visual" | "source";

export function EmbeddedEditor({ locale }: EmbeddedEditorProps) {
  const dictionary = useMemo(() => (locale === "zh" ? zh : en), [locale]);
  const editor = useCreateBlockNote({ schema, dictionary, uploadFile });
  const sourceEditorRef = useRef<SourceMarkdownEditorHandle | null>(null);
  const modeRef = useRef<EditorMode>("visual");
  const previousModeRef = useRef<EditorMode>("visual");
  const lastEmittedRef = useRef<string>("");
  const sourceMarkdownRef = useRef<string>("");
  const isApplyingExternalRef = useRef<boolean>(false);
  const [mode, setMode] = useState<EditorMode>("visual");
  const [sourceMarkdown, setSourceMarkdown] = useState("");
  const [aiContext, setAiContext] = useState<AISelectionContext | null>(null);
  // Menu-launched research popup. Boolean + top-center positioning, no anchor.
  const [researchOpen, setResearchOpen] = useState(false);

  const setSourceMarkdownValue = useCallback((markdown: string) => {
    sourceMarkdownRef.current = markdown;
    setSourceMarkdown(markdown);
  }, []);

  const applyMarkdownToVisual = useCallback(
    (markdown: string, options: { focus: boolean }) => {
      try {
        isApplyingExternalRef.current = true;
        const { stripped, formulas } = extractMathBlocks(markdown);
        const raw = editor.tryParseMarkdownToBlocks(stripped) as unknown as AnyBlock[];
        const withMath = rebuildMathBlocks(raw, formulas);
        const safe = withMath.length > 0 ? withMath : [{ type: "paragraph" }];
        // eslint-disable-next-line @typescript-eslint/no-explicit-any
        editor.replaceBlocks(editor.document, safe as any);
        lastEmittedRef.current = markdown;
        if (options.focus) {
          queueMicrotask(() => {
            try {
              placeCursorAtIdealStart(editor);
            } catch (err) {
              console.error("auto-focus on load failed:", err);
            }
          });
        }
      } catch (err) {
        console.error("loadMarkdown failed:", err);
      } finally {
        queueMicrotask(() => {
          isApplyingExternalRef.current = false;
        });
      }
    },
    [editor],
  );

  const handleSourceMarkdownChange = useCallback((markdown: string) => {
    setSourceMarkdownValue(markdown);
    if (markdown === lastEmittedRef.current) return;
    lastEmittedRef.current = markdown;
    postToHost({ type: "change", markdown });
  }, [setSourceMarkdownValue]);

  const switchMode = useCallback((nextMode: EditorMode) => {
    if (nextMode === modeRef.current) return;
    if (nextMode === "visual") {
      const currentSource = sourceEditorRef.current?.getMarkdown();
      if (currentSource !== undefined) {
        handleSourceMarkdownChange(currentSource);
      }
      isApplyingExternalRef.current = true;
    }
    modeRef.current = nextMode;
    setMode(nextMode);
  }, [handleSourceMarkdownChange]);

  useEffect(() => {
    window.editorBridge = {
      loadMarkdown: (markdown: string) => {
        setSourceMarkdownValue(markdown);
        applyMarkdownToVisual(markdown, { focus: modeRef.current === "visual" });
      },
      resolveUpload: (requestId: string, url: string) => {
        const pending = pendingUploads.get(requestId);
        if (!pending) return;
        pendingUploads.delete(requestId);
        pending.resolve(url);
      },
      rejectUpload: (requestId: string, message: string) => {
        const pending = pendingUploads.get(requestId);
        if (!pending) return;
        pendingUploads.delete(requestId);
        pending.reject(new Error(message));
      },
      setLocale: (code: string) => {
        window.__setEditorLocale__?.(code);
      },
      runPageAction: (action: string) => {
        if (modeRef.current === "source") {
          switchMode("visual");
        }
        requestAnimationFrame(() => {
          const ctx = captureWholeDocContext(editor, action);
          if (ctx) setAiContext(ctx);
        });
      },
      openResearch: () => {
        if (modeRef.current === "source") {
          switchMode("visual");
        }
        requestAnimationFrame(() => {
          setResearchOpen(true);
        });
      },
    };
    const uninstall = installAIBridge();
    const uninstallResearch = installResearchBridge();
    const uninstallEditorAgent = installEditorAgentBridge(editor, {
      getDocumentMarkdown: () => {
        if (modeRef.current === "source") {
          return sourceEditorRef.current?.getMarkdown() ?? sourceMarkdownRef.current;
        }
        return lastEmittedRef.current;
      },
      insertMarkdownAtCursor: (markdown: string) => {
        if (modeRef.current !== "source") return false;
        sourceEditorRef.current?.insertMarkdownAtCursor(markdown);
        return true;
      },
      replaceSelectionWithMarkdown: (markdown: string) => {
        if (modeRef.current !== "source") return false;
        sourceEditorRef.current?.replaceSelection(markdown);
        return true;
      },
    });
    postToHost({ type: "ready" });
    return () => {
      uninstall();
      uninstallResearch();
      uninstallEditorAgent();
    };
  }, [applyMarkdownToVisual, editor, setSourceMarkdownValue, switchMode]);

  useEffect(() => {
    modeRef.current = mode;
    const previous = previousModeRef.current;
    if (previous === mode) return;
    previousModeRef.current = mode;
    setAiContext(null);
    setResearchOpen(false);

    if (mode === "visual") {
      applyMarkdownToVisual(sourceMarkdownRef.current, { focus: true });
    } else {
      queueMicrotask(() => {
        sourceEditorRef.current?.focus();
      });
    }
  }, [applyMarkdownToVisual, mode]);

  // Lock the editor while the AI popup is open so the user can't type or
  // click into the document and shift the captured `from`/`to` positions out
  // from under us. The popup itself sits outside BlockNoteView so it still
  // accepts clicks and keyboard input.
  useEffect(() => {
    if (!editor) return;
    editor.isEditable = mode === "visual" && aiContext === null;
    return () => {
      editor.isEditable = true;
    };
  }, [aiContext, editor, mode]);

  const handleChange = useCallback(() => {
    if (isApplyingExternalRef.current) return;
    if (modeRef.current !== "visual") return;
    try {
      const inlined = blocksWithMathInlined(editor.document as unknown as AnyBlock[]);
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      const md = editor.blocksToMarkdownLossy(inlined as any);
      if (md === lastEmittedRef.current) return;
      lastEmittedRef.current = md;
      setSourceMarkdownValue(md);
      postToHost({ type: "change", markdown: md });
    } catch (err) {
      console.error("export markdown failed:", err);
    }
  }, [editor, setSourceMarkdownValue]);

  const openAskAI = useCallback(() => {
    // Slash menu fires asynchronously; the `/` trigger character and any
    // typed query string have been removed by BlockNote by the time our
    // onItemClick runs, so the captured selection is the user's real cursor
    // position. We capture in a microtask to be safe against any pending
    // transaction.
    queueMicrotask(() => {
      const ctx = captureSelectionContext(editor);
      if (!ctx) return;
      setAiContext(ctx);
      // After capturing the range, collapse the editor's PM selection to
      // the start of the captured range. BlockNote's FormattingToolbar is
      // anchored to an active text selection — collapsing it tells the
      // toolbar to dismiss naturally, so the user doesn't see both the
      // toolbar and the AI popup simultaneously. The captured `ctx`
      // already holds `from`/`to`, so the AI flow is unaffected.
      const view = editor.prosemirrorView;
      if (view) {
        try {
          // eslint-disable-next-line @typescript-eslint/no-explicit-any
          const TextSelection = (view.state.selection.constructor as any);
          if (TextSelection?.create) {
            const tr = view.state.tr.setSelection(
              TextSelection.create(view.state.doc, ctx.from),
            );
            view.dispatch(tr);
          }
        } catch {
          /* best-effort; falling back to leaving the selection alone */
        }
      }
    });
  }, [editor]);

  // Drag-handle ✨ Ask AI flow. Driven by SideMenuController → the custom
  // AILiquidGlassSideMenu, which passes us the hovered block.
  //
  // Selection wiring (why this works without editing AIPromptPopup): the
  // popup's Accept path falls back to `[editor.getTextCursorPosition().block]`
  // when `editor.getSelection()?.blocks` is empty. Calling
  // `editor.setSelection(block, block)` here makes `getSelection()` return
  // exactly `{ blocks: [block] }`, so Accept will `replaceBlocks([block], …)`
  // — the natural "rewrite this whole block" behavior we want.
  //
  // We also lock the editor (via the existing aiContext useEffect) right
  // after, freezing the PM doc while the popup is open so the captured
  // `from`/`to` stay valid.
  const openAskAIBlock = useCallback(
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    (block: any) => {
      try {
        editor.setSelection(block, block);
      } catch {
        // Some block types (e.g. nested blocks with unusual schemas) can
        // refuse setSelection; fall back to leaving selection alone.
      }
      queueMicrotask(() => {
        const ctx = captureBlockContext(editor, block);
        if (ctx) setAiContext(ctx);
      });
    },
    [editor],
  );

  useEffect(() => {
    return installSpaceTrigger({
      editor,
      onTrigger: () => openAskAI(),
    });
  }, [editor, openAskAI]);

  return (
    <div className="editor-shell">
      <div className="editor-mode-switcher" role="tablist" aria-label="Editor mode">
        <button
          type="button"
          role="tab"
          aria-selected={mode === "visual"}
          className="editor-mode-button"
          onClick={() => switchMode("visual")}
        >
          Visual
        </button>
        <button
          type="button"
          role="tab"
          aria-selected={mode === "source"}
          className="editor-mode-button"
          onClick={() => switchMode("source")}
        >
          Markdown
        </button>
      </div>
      {mode === "visual" && <CursorHalo editor={editor} />}
      <div
        className={
          mode === "visual" ? "visual-editor-pane" : "visual-editor-pane is-hidden"
        }
        aria-hidden={mode !== "visual"}
      >
        <BlockNoteView
          editor={editor}
          onChange={handleChange}
          slashMenu={false}
          formattingToolbar={false}
        >
          <SuggestionMenuController
            triggerCharacter="/"
            getItems={async (query) =>
              buildSlashItems(editor, query, locale, openAskAI)
            }
            suggestionMenuComponent={(props) => (
              <LiquidGlassSlashMenu {...props} locale={locale} />
            )}
          />
          <FormattingToolbarController
            formattingToolbar={() => (
              <LiquidGlassFormattingToolbar onAskAI={openAskAI} />
            )}
          />
          <SideMenuController
            sideMenu={(props) => (
              <AILiquidGlassSideMenu {...props} onAskAI={openAskAIBlock} />
            )}
          />
        </BlockNoteView>
      </div>
      {mode === "source" && (
        <SourceMarkdownEditor
          ref={sourceEditorRef}
          value={sourceMarkdown}
          onChange={handleSourceMarkdownChange}
        />
      )}
      {aiContext && (
        <AIPromptPopup
          editor={editor}
          context={aiContext}
          onClose={() => setAiContext(null)}
        />
      )}
      {researchOpen && (
        <AIResearchPopup
          editor={editor}
          onClose={() => setResearchOpen(false)}
        />
      )}
    </div>
  );
}
