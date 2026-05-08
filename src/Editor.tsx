import { useEffect, useCallback } from "react";
import { useCreateBlockNote } from "@blocknote/react";
import { BlockNoteView } from "@blocknote/mantine";
import type { PartialBlock } from "@blocknote/core";
import "@blocknote/mantine/style.css";

interface EditorProps {
  initialMarkdown: string;
  onMarkdownChange: (markdown: string) => void;
}

export function Editor({ initialMarkdown, onMarkdownChange }: EditorProps) {
  const editor = useCreateBlockNote();

  useEffect(() => {
    try {
      const blocks = editor.tryParseMarkdownToBlocks(initialMarkdown);
      const safe: PartialBlock[] =
        blocks.length > 0 ? blocks : [{ type: "paragraph" }];
      editor.replaceBlocks(editor.document, safe);
    } catch (err) {
      console.error("parse markdown failed:", err);
    }
  }, [initialMarkdown, editor]);

  const handleChange = useCallback(() => {
    try {
      const md = editor.blocksToMarkdownLossy(editor.document);
      onMarkdownChange(md);
    } catch (err) {
      console.error("export markdown failed:", err);
    }
  }, [editor, onMarkdownChange]);

  return <BlockNoteView editor={editor} onChange={handleChange} />;
}
