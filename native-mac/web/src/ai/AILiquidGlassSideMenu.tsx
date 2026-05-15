import {
  AddBlockButton,
  BlockColorsItem,
  DragHandleButton,
  DragHandleMenu,
  RemoveBlockItem,
  SideMenu,
  useComponentsContext,
  useExtensionState,
  type SideMenuProps,
} from "@blocknote/react";
import { SideMenuExtension } from "@blocknote/core/extensions";
import { type ReactNode } from "react";
import { AIIcon } from "./AIIcon";

// BlockNote's generic types are extremely deep (BSchema/ISchema/SSchema slots)
// and we don't customize the schema enough at this seam to want to thread
// them through. Treat the block as opaque at the boundary; consumers cast
// where they need typed access.
// eslint-disable-next-line @typescript-eslint/no-explicit-any
export type AnyBlock = any;

export interface AILiquidGlassSideMenuProps extends SideMenuProps {
  onAskAI: (block: AnyBlock) => void;
}

/**
 * Single item: ✨ Ask AI. Reads the currently-hovered block from the
 * SideMenuExtension store (same pattern the default RemoveBlockItem uses)
 * and calls onAskAI when clicked. Returns null when there's no block in
 * scope so the menu doesn't render an orphan row.
 */
function AskAIItem({
  onAskAI,
  children,
}: {
  onAskAI: (block: AnyBlock) => void;
  children: ReactNode;
}) {
  const Components = useComponentsContext()!;
  const block = useExtensionState(SideMenuExtension, {
    selector: (state) => state?.block,
  });

  if (block === undefined) {
    return null;
  }

  return (
    <Components.Generic.Menu.Item
      className={"bn-menu-item"}
      icon={<AIIcon size={16} />}
      onClick={() => onAskAI(block)}
    >
      {children}
    </Components.Generic.Menu.Item>
  );
}

/**
 * Custom SideMenu that preserves BlockNote's default rail (the + add button
 * and the ⋮ drag handle) but swaps the drag handle's dropdown for one that
 * starts with an "✨ Ask AI" item.
 *
 * Wiring note: BlockNote injects nothing on the dragHandleMenu component —
 * the menu reads block context from useExtensionState(SideMenuExtension),
 * not from props. We capture onAskAI via closure here rather than trying
 * to thread it through BlockNote's typed prop pipeline.
 */
export function AILiquidGlassSideMenu({
  onAskAI,
  ...sideMenuProps
}: AILiquidGlassSideMenuProps) {
  return (
    <SideMenu {...sideMenuProps}>
      <AddBlockButton />
      <DragHandleButton
        dragHandleMenu={() => (
          <DragHandleMenu>
            <AskAIItem onAskAI={onAskAI}>Ask AI</AskAIItem>
            <RemoveBlockItem>Delete</RemoveBlockItem>
            <BlockColorsItem>Colors</BlockColorsItem>
          </DragHandleMenu>
        )}
      />
    </SideMenu>
  );
}
