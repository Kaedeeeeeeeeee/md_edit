import {
  forwardRef,
  useEffect,
  useImperativeHandle,
  useMemo,
  useRef,
} from "react";
import { markdown } from "@codemirror/lang-markdown";
import { EditorState } from "@codemirror/state";
import { EditorView } from "@codemirror/view";
import { basicSetup } from "codemirror";

export interface SourceMarkdownEditorHandle {
  focus: () => void;
  getMarkdown: () => string;
  insertMarkdownAtCursor: (markdown: string) => void;
  replaceSelection: (markdown: string) => void;
}

interface SourceMarkdownEditorProps {
  value: string;
  onChange: (markdown: string) => void;
}

export const SourceMarkdownEditor = forwardRef<
  SourceMarkdownEditorHandle,
  SourceMarkdownEditorProps
>(function SourceMarkdownEditor({ value, onChange }, ref) {
  const hostRef = useRef<HTMLDivElement | null>(null);
  const viewRef = useRef<EditorView | null>(null);
  const applyingExternalRef = useRef(false);
  const initialValueRef = useRef(value);
  const onChangeRef = useRef(onChange);

  useEffect(() => {
    onChangeRef.current = onChange;
  }, [onChange]);

  const extensions = useMemo(
    () => [
      basicSetup,
      markdown(),
      EditorView.lineWrapping,
      EditorView.updateListener.of((update) => {
        if (!update.docChanged || applyingExternalRef.current) return;
        onChangeRef.current(update.state.doc.toString());
      }),
    ],
    [],
  );

  useEffect(() => {
    const host = hostRef.current;
    if (!host) return;

    const view = new EditorView({
      parent: host,
      state: EditorState.create({
        doc: initialValueRef.current,
        extensions,
      }),
    });
    viewRef.current = view;

    return () => {
      view.destroy();
      viewRef.current = null;
    };
  }, [extensions]);

  useEffect(() => {
    const view = viewRef.current;
    if (!view) return;

    const current = view.state.doc.toString();
    if (current === value) return;

    applyingExternalRef.current = true;
    view.dispatch({
      changes: { from: 0, to: current.length, insert: value },
    });
    queueMicrotask(() => {
      applyingExternalRef.current = false;
    });
  }, [value]);

  useImperativeHandle(
    ref,
    () => ({
      focus: () => {
        viewRef.current?.focus();
      },
      getMarkdown: () => viewRef.current?.state.doc.toString() ?? value,
      insertMarkdownAtCursor: (markdownText: string) => {
        const view = viewRef.current;
        if (!view) return;
        view.dispatch(view.state.replaceSelection(markdownText));
        view.focus();
      },
      replaceSelection: (markdownText: string) => {
        const view = viewRef.current;
        if (!view) return;
        view.dispatch(view.state.replaceSelection(markdownText));
        view.focus();
      },
    }),
    [value],
  );

  return <div ref={hostRef} className="source-editor-host" />;
});
