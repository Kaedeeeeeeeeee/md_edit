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
      resolveUpload: (requestId: string, url: string) => void;
      rejectUpload: (requestId: string, message: string) => void;
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
  const editor = useCreateBlockNote({ schema, uploadFile });
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
