import { useCallback, useEffect, useRef } from "react";
import { useCreateBlockNote } from "@blocknote/react";
import { BlockNoteView } from "@blocknote/mantine";
import type { PartialBlock } from "@blocknote/core";
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

export function EmbeddedEditor() {
  const editor = useCreateBlockNote();
  const lastEmittedRef = useRef<string>("");
  const isApplyingExternalRef = useRef<boolean>(false);

  // Expose a Swift-callable hook for replacing the editor content.
  useEffect(() => {
    window.editorBridge = {
      loadMarkdown: (markdown: string) => {
        try {
          isApplyingExternalRef.current = true;
          const blocks = editor.tryParseMarkdownToBlocks(markdown);
          const safe: PartialBlock[] =
            blocks.length > 0 ? blocks : [{ type: "paragraph" }];
          editor.replaceBlocks(editor.document, safe);
          lastEmittedRef.current = markdown;
        } catch (err) {
          console.error("loadMarkdown failed:", err);
        } finally {
          // BlockNote fires onChange synchronously after replaceBlocks; keep the
          // flag set until the next microtask so we can swallow that echo.
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
      const md = editor.blocksToMarkdownLossy(editor.document);
      if (md === lastEmittedRef.current) return;
      lastEmittedRef.current = md;
      postToHost({ type: "change", markdown: md });
    } catch (err) {
      console.error("export markdown failed:", err);
    }
  }, [editor]);

  return <BlockNoteView editor={editor} onChange={handleChange} />;
}
