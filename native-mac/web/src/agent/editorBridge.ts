/**
 * JS-side surface the native SwiftUI AI Assistant panel calls into via
 * `WKWebView.evaluateJavaScript`. The chat brain and persistence live on the
 * Swift side now (`AgentChatController` + `AgentChatStore` + `AIService`); the
 * editor itself is still BlockNote in the WebView, so the SwiftUI panel
 * borrows it for three operations:
 *
 *   1. Read the whole document as markdown (for "include current doc" context).
 *   2. Insert the assistant's markdown at the cursor.
 *   3. Replace the user's multi-block selection with the assistant's markdown.
 *
 * All three are exposed as methods on `window.editorBridge` so Swift can call
 * them with `evaluateJavaScript`. Two are fire-and-forget; the doc-markdown
 * getter returns the string synchronously to evaluateJavaScript's completion
 * handler.
 *
 * Insert behavior: if the cursor is in an empty paragraph we REPLACE it (to
 * avoid stranding a blank line above the inserted content), otherwise we
 * INSERT after the current block. Replace behavior: if there's a multi-block
 * selection we replace those blocks; with no selection, fall back to insert.
 */

// eslint-disable-next-line @typescript-eslint/no-explicit-any
type AnyEditor = any;

type AnyBlock = { type: string; content?: unknown };

export interface EditorAgentBridgeOverrides {
  getDocumentMarkdown?: () => string;
  insertMarkdownAtCursor?: (markdown: string) => boolean;
  replaceSelectionWithMarkdown?: (markdown: string) => boolean;
}

function isEmptyParagraph(block: AnyBlock | undefined | null): boolean {
  if (!block) return false;
  if (block.type !== "paragraph") return false;
  const content = block.content;
  if (!content) return true;
  if (Array.isArray(content) && content.length === 0) return true;
  return false;
}

function insertMarkdownAtCursor(editor: AnyEditor, markdown: string) {
  if (!editor) return;
  const blocks = editor.tryParseMarkdownToBlocks?.(markdown);
  if (!blocks || blocks.length === 0) return;

  const cursor = editor.getTextCursorPosition?.();
  if (!cursor || !cursor.block) return;

  const block = cursor.block;
  if (isEmptyParagraph(block)) {
    editor.replaceBlocks?.([block], blocks);
  } else {
    editor.insertBlocks?.(blocks, block, "after");
  }
  editor.prosemirrorView?.focus?.();
}

function replaceSelectionWithMarkdown(editor: AnyEditor, markdown: string) {
  if (!editor) return;
  const sel = editor.getSelection?.();
  const targetBlocks = sel?.blocks?.length ? sel.blocks : null;
  if (!targetBlocks) {
    insertMarkdownAtCursor(editor, markdown);
    return;
  }
  const blocks = editor.tryParseMarkdownToBlocks?.(markdown);
  if (!blocks || blocks.length === 0) return;
  editor.replaceBlocks?.(targetBlocks, blocks);
  editor.prosemirrorView?.focus?.();
}

function getDocumentMarkdown(editor: AnyEditor): string {
  if (!editor) return "";
  try {
    return editor.blocksToMarkdownLossy?.(editor.document) ?? "";
  } catch {
    return "";
  }
}

/**
 * Mounts the three editor-bridge methods on `window.editorBridge`. Returns
 * an uninstall function that restores any previous handlers, mirroring the
 * idempotency pattern used by `installAIBridge`.
 */
export function installEditorAgentBridge(
  editor: AnyEditor,
  overrides: EditorAgentBridgeOverrides = {},
): () => void {
  const bridge = window.editorBridge;
  if (!bridge) {
    console.warn("[agent] editorBridge not initialized; installEditorAgentBridge no-op");
    return () => {};
  }

  const previousGet = bridge.aiGetDocumentMarkdown;
  const previousInsert = bridge.aiInsertAtCursor;
  const previousReplace = bridge.aiReplaceSelection;

  const getHandler = () => overrides.getDocumentMarkdown?.() ?? getDocumentMarkdown(editor);
  const insertHandler = (markdown: string) => {
    if (overrides.insertMarkdownAtCursor?.(markdown)) return;
    insertMarkdownAtCursor(editor, markdown);
  };
  const replaceHandler = (markdown: string) => {
    if (overrides.replaceSelectionWithMarkdown?.(markdown)) return;
    replaceSelectionWithMarkdown(editor, markdown);
  };

  bridge.aiGetDocumentMarkdown = getHandler;
  bridge.aiInsertAtCursor = insertHandler;
  bridge.aiReplaceSelection = replaceHandler;

  return () => {
    if (window.editorBridge?.aiGetDocumentMarkdown === getHandler) {
      window.editorBridge.aiGetDocumentMarkdown = previousGet;
    }
    if (window.editorBridge?.aiInsertAtCursor === insertHandler) {
      window.editorBridge.aiInsertAtCursor = previousInsert;
    }
    if (window.editorBridge?.aiReplaceSelection === replaceHandler) {
      window.editorBridge.aiReplaceSelection = previousReplace;
    }
  };
}
