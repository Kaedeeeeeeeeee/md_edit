import { useEffect, useRef, useState } from "react";
import { createReactBlockSpec } from "@blocknote/react";
import katex from "katex";
import "katex/dist/katex.min.css";

const PLACEHOLDER = "x^2 + y^2 = z^2";

/// Custom BlockNote block that renders LaTeX through KaTeX.  Click to edit
/// in a textarea overlay; Esc / blur commits the edit.
export const MathBlock = createReactBlockSpec(
  {
    type: "math",
    propSchema: {
      latex: { default: PLACEHOLDER },
    },
    content: "none",
  },
  {
    render: ({ block, editor }) => {
      const [editing, setEditing] = useState(false);
      const [draft, setDraft] = useState(block.props.latex);
      const containerRef = useRef<HTMLDivElement>(null);
      const textareaRef = useRef<HTMLTextAreaElement>(null);

      useEffect(() => {
        setDraft(block.props.latex);
      }, [block.props.latex]);

      useEffect(() => {
        if (editing) {
          textareaRef.current?.focus();
          textareaRef.current?.select();
        }
      }, [editing]);

      useEffect(() => {
        if (editing) return;
        if (!containerRef.current) return;
        try {
          katex.render(block.props.latex || PLACEHOLDER, containerRef.current, {
            displayMode: true,
            throwOnError: false,
            errorColor: "#cc0000",
            output: "html",
          });
        } catch (err) {
          containerRef.current.textContent = String(err);
        }
      }, [block.props.latex, editing]);

      const commit = () => {
        if (draft !== block.props.latex) {
          editor.updateBlock(block, { props: { latex: draft } });
        }
        setEditing(false);
      };

      if (editing) {
        return (
          <div className="math-block math-block--editing">
            <textarea
              ref={textareaRef}
              className="math-block__textarea"
              value={draft}
              spellCheck={false}
              onChange={(e) => setDraft(e.target.value)}
              onBlur={commit}
              onKeyDown={(e) => {
                if (e.key === "Escape") {
                  e.preventDefault();
                  setDraft(block.props.latex); // discard
                  setEditing(false);
                } else if (e.key === "Enter" && (e.metaKey || e.ctrlKey)) {
                  e.preventDefault();
                  commit();
                }
              }}
              rows={Math.max(2, draft.split("\n").length + 1)}
            />
            <div className="math-block__hint">
              ⌘↩ to render · Esc to discard
            </div>
          </div>
        );
      }

      return (
        <div
          className="math-block"
          ref={containerRef}
          role="button"
          tabIndex={0}
          onClick={() => setEditing(true)}
          onKeyDown={(e) => {
            if (e.key === "Enter" || e.key === " ") {
              e.preventDefault();
              setEditing(true);
            }
          }}
          title="Click to edit LaTeX"
        />
      );
    },
  },
);
