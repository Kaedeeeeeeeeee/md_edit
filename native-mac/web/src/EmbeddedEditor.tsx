import { useCallback, useEffect, useRef } from "react";
import {
  useCreateBlockNote,
  SuggestionMenuController,
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
import { MathBlock } from "./MathBlock";
import "@blocknote/mantine/style.css";

declare global {
  interface Window {
    editorBridge?: {
      loadMarkdown: (markdown: string) => void;
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

// ---- Slash menu helpers ----------------------------------------------------

function buildSlashItems(editor: Editor, query: string): DefaultReactSuggestionItem[] {
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const defaults = getDefaultReactSlashMenuItems(editor as any);
  const custom: DefaultReactSuggestionItem[] = [
    {
      title: "Math",
      subtext: "LaTeX equation block ($$…$$)",
      onItemClick: () => {
        // eslint-disable-next-line @typescript-eslint/no-explicit-any
        insertOrUpdateBlockForSlashMenu(editor as any, {
          type: "math",
          props: { latex: "x^2 + y^2 = z^2" },
          // eslint-disable-next-line @typescript-eslint/no-explicit-any
        } as any);
      },
      aliases: ["math", "latex", "equation", "tex", "formula"],
      group: "Advanced",
      icon: <span style={{ fontFamily: "serif", fontWeight: 700 }}>∑</span>,
    },
  ];
  return filterSuggestionItems([...defaults, ...custom], query);
}

// ---- Component -------------------------------------------------------------

export function EmbeddedEditor() {
  const editor = useCreateBlockNote({ schema });
  const lastEmittedRef = useRef<string>("");
  const isApplyingExternalRef = useRef<boolean>(false);

  useEffect(() => {
    window.editorBridge = {
      loadMarkdown: (markdown: string) => {
        try {
          isApplyingExternalRef.current = true;
          const { stripped, formulas } = extractMathBlocks(markdown);
          const raw = editor.tryParseMarkdownToBlocks(stripped) as unknown as AnyBlock[];
          const withMath = rebuildMathBlocks(raw, formulas);
          const safe = withMath.length > 0 ? withMath : [{ type: "paragraph" }];
          // eslint-disable-next-line @typescript-eslint/no-explicit-any
          editor.replaceBlocks(editor.document, safe as any);
          lastEmittedRef.current = markdown;
        } catch (err) {
          console.error("loadMarkdown failed:", err);
        } finally {
          queueMicrotask(() => {
            isApplyingExternalRef.current = false;
          });
        }
      },
    };
    postToHost({ type: "ready" });
  }, [editor]);

  const handleChange = useCallback(() => {
    if (isApplyingExternalRef.current) return;
    try {
      const inlined = blocksWithMathInlined(editor.document as unknown as AnyBlock[]);
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      const md = editor.blocksToMarkdownLossy(inlined as any);
      if (md === lastEmittedRef.current) return;
      lastEmittedRef.current = md;
      postToHost({ type: "change", markdown: md });
    } catch (err) {
      console.error("export markdown failed:", err);
    }
  }, [editor]);

  return (
    <BlockNoteView editor={editor} onChange={handleChange} slashMenu={false}>
      <SuggestionMenuController
        triggerCharacter="/"
        getItems={async (query) => buildSlashItems(editor, query)}
      />
    </BlockNoteView>
  );
}
