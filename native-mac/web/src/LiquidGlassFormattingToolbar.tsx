import { getFormattingToolbarItems } from "@blocknote/react";
import { AIIcon } from "./ai/AIIcon";

export interface LiquidGlassFormattingToolbarProps {
  onAskAI?: () => void;
}

export function LiquidGlassFormattingToolbar({
  onAskAI,
}: LiquidGlassFormattingToolbarProps = {}) {
  return (
    <div className="lg-toolbar-root" role="toolbar">
      {onAskAI && (
        <>
          <button
            type="button"
            // Prevent the mousedown from collapsing the editor selection;
            // the formatting toolbar relies on the selection being preserved
            // when its buttons are clicked.
            onMouseDown={(e) => e.preventDefault()}
            onClick={onAskAI}
            title="Ask AI"
            aria-label="Ask AI"
            style={{ display: "inline-flex", alignItems: "center", gap: 4 }}
          >
            <AIIcon size={14} />
            <span>AI</span>
          </button>
          <hr role="separator" />
        </>
      )}
      {getFormattingToolbarItems()}
    </div>
  );
}
