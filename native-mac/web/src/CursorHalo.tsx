import { useEffect, useRef, useState } from "react";

// BlockNote's generic editor types are deep enough that threading them through
// just to read `prosemirrorView` adds noise without buying safety. Treat the
// editor as opaque here.
// eslint-disable-next-line @typescript-eslint/no-explicit-any
type AnyEditor = any;

interface HaloState {
  visible: boolean;
  /** viewport-relative caret left edge, in CSS px */
  left: number;
  /** viewport-relative caret top, in CSS px */
  top: number;
  /** caret height = line-box height at the cursor position */
  height: number;
}

/**
 * A soft pulsing blue glow that follows the text cursor — inspired by iA
 * Writer's "breathing" caret. We keep the native browser caret visible
 * (recolored blue via `caret-color`) so IME composition stays accurate; this
 * component just renders an additional blurred halo behind it that pulses in
 * opacity and spread.
 *
 * Hidden when: editor is unfocused, the selection is a non-empty range, or
 * the editor is non-editable (e.g. while the AI popup is open).
 */
export function CursorHalo({ editor }: { editor: AnyEditor }) {
  const [state, setState] = useState<HaloState>({
    visible: false,
    left: 0,
    top: 0,
    height: 20,
  });
  // We measure on every relevant event, but coalesce via rAF so a typing burst
  // doesn't trigger N getBoundingClientRect calls per frame.
  const rafRef = useRef<number | null>(null);

  useEffect(() => {
    const view = editor?.prosemirrorView;
    if (!view) return;
    const dom = view.dom as HTMLElement | null;
    if (!dom) return;

    function measure() {
      rafRef.current = null;
      const v = editor.prosemirrorView;
      if (!v) {
        setState((s) => (s.visible ? { ...s, visible: false } : s));
        return;
      }
      const focused = typeof v.hasFocus === "function" ? v.hasFocus() : false;
      const editable = editor.isEditable !== false;
      const pmSel = v.state.selection;
      const collapsed = pmSel.from === pmSel.to;
      if (!focused || !editable || !collapsed) {
        setState((s) => (s.visible ? { ...s, visible: false } : s));
        return;
      }

      // Measurement strategy: we want to match the native caret's height,
      // which adapts to the FONT RUN at the cursor position (English vs CJK
      // characters at the same nominal font-size render at different
      // heights). A few fallbacks because no single browser API gives us
      // exactly that for a collapsed range.
      //
      //  1. Collapsed range's own bounding rect — when WebKit returns a
      //     non-zero height (rare for empty paragraphs), this is exact.
      //  2. Probe the adjacent character: clone the range, extend it by
      //     one character left (or right at line start), measure that
      //     single character's rect. The rect carries the font run's
      //     metrics, so it shrinks for English and grows for CJK — matches
      //     the native caret's behaviour.
      //  3. coordsAtPos for layout, font-size from the DOM as a floor —
      //     only kicks in on completely empty blocks where no adjacent
      //     glyph exists to probe.
      let left = 0;
      let top = 0;
      let height = 0;
      let measured = false;

      const winSel = window.getSelection();
      const origRange =
        winSel && winSel.rangeCount > 0 ? winSel.getRangeAt(0) : null;

      if (origRange && origRange.collapsed) {
        const directRect = origRange.getBoundingClientRect();
        if (directRect.height > 0) {
          left = directRect.left;
          top = directRect.top;
          height = directRect.height;
          measured = true;
        }
      }

      if (!measured && origRange && origRange.collapsed) {
        // Probe a neighbouring glyph.
        const container = origRange.startContainer;
        const offset = origRange.startOffset;
        if (container.nodeType === Node.TEXT_NODE) {
          const textLen = container.textContent?.length ?? 0;
          const probe = document.createRange();
          let probedRight = false; // true = probe is to the LEFT of cursor
          try {
            if (offset > 0) {
              probe.setStart(container, offset - 1);
              probe.setEnd(container, offset);
              probedRight = true;
            } else if (offset < textLen) {
              probe.setStart(container, offset);
              probe.setEnd(container, offset + 1);
              probedRight = false;
            }
            const rect = probe.getBoundingClientRect();
            if (rect.height > 0) {
              // Probe gives us a horizontally-accurate caret position and
              // a vertical anchor near the baseline area. We do NOT use
              // its height directly — Chinese glyphs render much taller
              // than English at the same nominal font-size and the user
              // wants the halo to stay a uniform English-style height
              // regardless of font run. Final height is computed below
              // from the parent element's `font-size`, with the bottom
              // pinned to `rect.bottom` so the halo sits on the
              // baseline-ish area no matter which font is in play.
              left = probedRight ? rect.right : rect.left;
              top = rect.top; // provisional — overwritten below
              height = rect.height;
              measured = true;
            }
          } catch {
            /* fall through */
          }
        }
      }

      if (!measured) {
        try {
          const coords = v.coordsAtPos(pmSel.from);
          left = coords.left;
          top = coords.top;
          height = coords.bottom - coords.top;
        } catch {
          setState((s) => (s.visible ? { ...s, visible: false } : s));
          return;
        }
        // On empty blocks coordsAtPos may give the full block rect (way too
        // tall) or a near-zero rect. Clamp to the DOM element's font-size,
        // not its line-height — line-height includes leading and would
        // over-extend the halo on lines that don't actually have CJK glyphs.
        try {
          const domPos = v.domAtPos(pmSel.from);
          let node: Node | null = domPos.node;
          if (node && node.nodeType === Node.TEXT_NODE) {
            node = node.parentElement;
          }
          if (node && node instanceof Element) {
            const fs = parseFloat(window.getComputedStyle(node).fontSize);
            if (!Number.isNaN(fs) && fs > 0) {
              const target = fs * 1.25;
              if (height < 12 || height > target * 2) {
                height = target;
              }
            }
          }
        } catch {
          /* keep coordsAtPos value */
        }
        if (height < 12) height = 16;
        measured = true;
      }

      // Force a uniform English-style height regardless of which font run
      // is at the cursor. The user prefers the halo NOT to grow taller next
      // to CJK glyphs; only the native browser caret (which we don't
      // control) adapts to font metrics. We bottom-anchor to the previously
      // measured `top + height` so the halo sits in the baseline area of
      // whatever rect we found.
      try {
        const domPos = v.domAtPos(pmSel.from);
        let node: Node | null = domPos.node;
        if (node && node.nodeType === Node.TEXT_NODE) {
          node = node.parentElement;
        }
        if (node && node instanceof Element) {
          const fs = parseFloat(window.getComputedStyle(node).fontSize);
          if (!Number.isNaN(fs) && fs > 0) {
            const uniformHeight = fs * 1.2;
            const bottom = top + height;
            height = uniformHeight;
            top = bottom - uniformHeight;
          }
        }
      } catch {
        /* keep measured height */
      }

      setState({ visible: true, left, top, height });
    }

    function schedule() {
      if (rafRef.current != null) return;
      rafRef.current = requestAnimationFrame(measure);
    }

    // Initial measure so first focus shows the halo without a wait.
    schedule();

    // selectionchange fires for arrow keys, click placement, and IME-driven
    // selection moves. It's the broadest signal we have for "caret moved".
    const onSelectionChange = () => schedule();
    document.addEventListener("selectionchange", onSelectionChange);

    // `input` covers the actual character-typed case — by the time it fires,
    // the doc has been updated and the new cursor position is final.
    const onInput = () => schedule();
    dom.addEventListener("input", onInput);

    const onFocus = () => schedule();
    const onBlur = () => setState((s) => (s.visible ? { ...s, visible: false } : s));
    dom.addEventListener("focus", onFocus);
    dom.addEventListener("blur", onBlur);

    // The PM view lives inside a scrollable container — when the editor
    // scrolls, viewport coordinates of the caret change without any selection
    // event firing. Capture at the window level to catch any ancestor scroll.
    const onScroll = () => schedule();
    window.addEventListener("scroll", onScroll, true);

    // Window resizes reflow text so the cursor's line may move.
    const onResize = () => schedule();
    window.addEventListener("resize", onResize);

    return () => {
      if (rafRef.current != null) cancelAnimationFrame(rafRef.current);
      rafRef.current = null;
      document.removeEventListener("selectionchange", onSelectionChange);
      dom.removeEventListener("input", onInput);
      dom.removeEventListener("focus", onFocus);
      dom.removeEventListener("blur", onBlur);
      window.removeEventListener("scroll", onScroll, true);
      window.removeEventListener("resize", onResize);
    };
  }, [editor]);

  if (!state.visible) return null;
  return (
    <div
      className="lg-cursor-halo"
      style={{
        left: state.left,
        top: state.top,
        height: state.height,
      }}
      aria-hidden="true"
    />
  );
}
