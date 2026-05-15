import { useEffect, useMemo, useRef, type ReactNode } from "react";
import type {
  DefaultReactSuggestionItem,
  SuggestionMenuProps,
} from "@blocknote/react";
import { getDict, type AppLocale } from "./dict";
import { AIIcon } from "./ai/AIIcon";

const MOD_SYMBOL: Record<string, string> = {
  Mod: "⌘",
  Cmd: "⌘",
  Ctrl: "⌃",
  Alt: "⌥",
  Shift: "⇧",
  "⌘": "⌘",
};

function prettyBadge(badge: string): string {
  return badge
    .split("-")
    .map((part) => MOD_SYMBOL[part] ?? part.toUpperCase())
    .join("");
}

type Props = SuggestionMenuProps<DefaultReactSuggestionItem> & {
  locale: AppLocale;
};

export function LiquidGlassSlashMenu(props: Props) {
  const { items, loadingState, selectedIndex, onItemClick, locale } = props;
  const selectedRef = useRef<HTMLElement | null>(null);
  const dict = getDict(locale);

  // The "Ask AI" item is intentionally placed at the END of the items array
  // by buildSlashItems so the default selectedIndex=0 still lands on the
  // first regular item (Heading 1). We pull it out here and render it as a
  // pinned chip at the top so the visual order matches the user's mental
  // model (AI = top, prominent). Keyboard navigation continues to use the
  // logical index — pressing Up at index 0 wraps to the last index = AI,
  // which our render highlights in the chip at the top.
  const aiLogicalIndex = items.findIndex((it) => it.title === dict.aiTitle);
  const aiItem = aiLogicalIndex >= 0 ? items[aiLogicalIndex] : null;
  const aiSelected = aiLogicalIndex >= 0 && selectedIndex === aiLogicalIndex;
  const regularEntries = items
    .map((item, logicalIndex) => ({ item, logicalIndex }))
    .filter((e) => e.logicalIndex !== aiLogicalIndex);

  useEffect(() => {
    selectedRef.current?.scrollIntoView({ block: "nearest" });
  }, [selectedIndex]);

  const rows = useMemo<ReactNode[]>(() => {
    const out: ReactNode[] = [];
    let currentGroup: string | undefined;
    regularEntries.forEach(({ item, logicalIndex }, renderedIdx) => {
      if (item.group !== currentGroup) {
        currentGroup = item.group;
        if (currentGroup) {
          out.push(
            <div
              key={`g-${currentGroup}-${renderedIdx}`}
              className="lg-slash-label"
            >
              {currentGroup}
            </div>,
          );
        }
      }
      const isSelected = logicalIndex === selectedIndex;
      out.push(
        <div
          key={`item-${logicalIndex}-${item.title}`}
          ref={isSelected ? (selectedRef as React.RefObject<HTMLDivElement | null>) : undefined}
          className="lg-slash-item"
          data-selected={isSelected || undefined}
          role="option"
          aria-selected={isSelected || undefined}
          id={`bn-suggestion-menu-item-${logicalIndex}`}
          onMouseDown={(e) => e.preventDefault()}
          onClick={() => onItemClick?.(item)}
        >
          {item.icon && <div className="lg-slash-icon">{item.icon}</div>}
          <div className="lg-slash-body">
            <div className="lg-slash-title">{item.title}</div>
            {item.subtext && (
              <div className="lg-slash-subtext">{item.subtext}</div>
            )}
          </div>
          {item.badge && (
            <div className="lg-slash-badge">{prettyBadge(item.badge)}</div>
          )}
        </div>,
      );
    });
    return out;
  }, [regularEntries, selectedIndex, onItemClick]);

  const showLoader =
    loadingState === "loading-initial" || loadingState === "loading";
  const showEmpty = items.length === 0 && loadingState !== "loading-initial";

  return (
    <div className="lg-slash-root" id="bn-suggestion-menu" role="listbox">
      {aiItem && (
        <button
          type="button"
          className="lg-slash-pinned"
          data-selected={aiSelected || undefined}
          ref={aiSelected ? (selectedRef as React.RefObject<HTMLButtonElement | null>) : undefined}
          role="option"
          aria-selected={aiSelected || undefined}
          id={`bn-suggestion-menu-item-${aiLogicalIndex}`}
          // Prevent the editor selection from collapsing on mousedown so the
          // captured selection survives into the AI popup.
          onMouseDown={(e) => e.preventDefault()}
          onClick={() => onItemClick?.(aiItem)}
        >
          <div className="lg-slash-icon">
            <AIIcon size={16} />
          </div>
          <div className="lg-slash-body">
            <div className="lg-slash-title">{aiItem.title}</div>
            {aiItem.subtext && (
              <div className="lg-slash-subtext">{aiItem.subtext}</div>
            )}
          </div>
        </button>
      )}
      {rows}
      {showEmpty && <div className="lg-slash-empty">{dict.noResults}</div>}
      {showLoader && (
        <div className="lg-slash-loader" aria-hidden="true">
          <span />
          <span />
          <span />
        </div>
      )}
    </div>
  );
}
