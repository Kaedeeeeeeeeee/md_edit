// eslint-disable-next-line @typescript-eslint/no-explicit-any
type AnyEditor = any;

export interface SpaceTriggerOptions {
  editor: AnyEditor;
  onTrigger: () => void;
}

/**
 * Installs a keydown listener that fires `onTrigger` when the user presses
 * Space on a completely empty paragraph block (cursor at the start of an
 * empty textblock). Returns an unsubscribe function.
 *
 * Returns false from event handling to let the editor handle non-trigger
 * cases normally.
 *
 * Detection logic (ProseMirror level):
 *   - The selection must be a TextSelection (not NodeSelection)
 *   - selection.from === selection.to (empty selection, no range)
 *   - $from.parent.type.name === "paragraph"
 *   - $from.parent.content.size === 0  (empty paragraph)
 *   - $from.parentOffset === 0  (cursor at the start)
 *   - The editor must be editable (isEditable === true)
 *   - Modifier keys must NOT be held (no Shift/Cmd/Ctrl/Alt+Space)
 */
export function installSpaceTrigger({ editor, onTrigger }: SpaceTriggerOptions): () => void {
  const handler = (e: KeyboardEvent) => {
    // Match a bare space keystroke. Skip if modifiers or IME composition.
    if (e.key !== " " || e.shiftKey || e.metaKey || e.ctrlKey || e.altKey || e.isComposing) {
      return;
    }
    const view = editor.prosemirrorView;
    if (!view || !editor.isEditable) return;

    const { state } = view;
    const sel = state.selection;
    if (sel.from !== sel.to) return;  // non-empty selection (a range), don't intercept

    const $from = sel.$from;
    if ($from.parent.type.name !== "paragraph") return;
    if ($from.parent.content.size !== 0) return;
    if ($from.parentOffset !== 0) return;

    e.preventDefault();
    e.stopPropagation();
    onTrigger();
  };

  // Use the editor's DOM element so we don't intercept space anywhere else on
  // the page (the agent panel, settings, etc.).
  const root: HTMLElement | null = editor.domElement;
  if (!root) return () => {};

  // Capture phase so we run before ProseMirror's own keydown chain. Without
  // capture, ProseMirror's handleKeyDown may already have inserted a space.
  root.addEventListener("keydown", handler, true);
  return () => {
    root.removeEventListener("keydown", handler, true);
  };
}
