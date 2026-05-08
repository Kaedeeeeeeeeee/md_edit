import { useCallback, useEffect, useRef, useState } from "react";
import { open, save, ask } from "@tauri-apps/plugin-dialog";
import { readTextFile, writeTextFile } from "@tauri-apps/plugin-fs";
import { listen } from "@tauri-apps/api/event";
import { getCurrentWindow } from "@tauri-apps/api/window";
import { Editor } from "./Editor";
import { Sidebar } from "./Sidebar";
import { SidebarIcon } from "./icons";
import "./App.css";

const WELCOME_MARKDOWN = `# Welcome to Marktext Next

A **Tauri + BlockNote** prototype for a Notion-style native markdown editor.

## Try these

- Type \`/\` to open the slash menu
- Hover any block to grab its drag handle
- Type \`# \`, \`## \`, \`- \`, \`> \`, \`\\\`\\\`\\\`\` to switch block types
- Open a folder via **File → Open Folder…** (⌘⇧O) to browse your markdown library

| feature | works |
|---------|-------|
| tables | yes |
| code blocks | yes |
| task lists | yes |

\`\`\`js
console.log("hello from a code block");
\`\`\`

> Use ⌘O to open a single file, ⌘S to save, ⌘\\ to toggle the sidebar.
`;

function App() {
  const [filePath, setFilePath] = useState<string | null>(null);
  const [folderPath, setFolderPath] = useState<string | null>(null);
  const [loadedMarkdown, setLoadedMarkdown] = useState<string>(WELCOME_MARKDOWN);
  const [dirty, setDirty] = useState(false);
  const [sidebarOpen, setSidebarOpen] = useState(true);
  const currentMarkdownRef = useRef<string>(WELCOME_MARKDOWN);

  const filePathRef = useRef<string | null>(null);
  const dirtyRef = useRef<boolean>(false);
  useEffect(() => {
    filePathRef.current = filePath;
  }, [filePath]);
  useEffect(() => {
    dirtyRef.current = dirty;
  }, [dirty]);

  const handleEditorChange = useCallback((md: string) => {
    currentMarkdownRef.current = md;
    setDirty(true);
  }, []);

  const confirmDiscardIfDirty = useCallback(async (): Promise<boolean> => {
    if (!dirtyRef.current) return true;
    const ok = await ask("You have unsaved changes. Discard them?", {
      title: "Discard changes?",
      kind: "warning",
    });
    return ok;
  }, []);

  const loadFromPath = useCallback(async (path: string) => {
    const content = await readTextFile(path);
    setFilePath(path);
    setLoadedMarkdown(content);
    currentMarkdownRef.current = content;
    setDirty(false);
  }, []);

  const handleNew = useCallback(async () => {
    if (!(await confirmDiscardIfDirty())) return;
    setFilePath(null);
    setLoadedMarkdown("");
    currentMarkdownRef.current = "";
    setDirty(false);
  }, [confirmDiscardIfDirty]);

  const handleOpenFile = useCallback(async () => {
    if (!(await confirmDiscardIfDirty())) return;
    try {
      const picked = await open({
        multiple: false,
        directory: false,
        filters: [{ name: "Markdown", extensions: ["md", "markdown", "txt"] }],
      });
      const path = typeof picked === "string" ? picked : null;
      if (!path) return;
      await loadFromPath(path);
    } catch (err) {
      console.error("open file failed:", err);
      alert(`Open failed: ${err}`);
    }
  }, [confirmDiscardIfDirty, loadFromPath]);

  const handleOpenFolder = useCallback(async () => {
    try {
      const picked = await open({ directory: true, multiple: false });
      const path = typeof picked === "string" ? picked : null;
      if (!path) return;
      setFolderPath(path);
      setSidebarOpen(true);
    } catch (err) {
      console.error("open folder failed:", err);
      alert(`Open folder failed: ${err}`);
    }
  }, []);

  const handleSelectFromTree = useCallback(
    async (path: string) => {
      if (!(await confirmDiscardIfDirty())) return;
      try {
        await loadFromPath(path);
      } catch (err) {
        console.error("load file failed:", err);
        alert(`Load failed: ${err}`);
      }
    },
    [confirmDiscardIfDirty, loadFromPath],
  );

  const handleSave = useCallback(async () => {
    try {
      let path = filePathRef.current;
      if (!path) {
        const picked = await save({
          defaultPath: "untitled.md",
          filters: [{ name: "Markdown", extensions: ["md"] }],
        });
        path = typeof picked === "string" ? picked : null;
      }
      if (!path) return;
      await writeTextFile(path, currentMarkdownRef.current);
      setFilePath(path);
      setDirty(false);
    } catch (err) {
      console.error("save failed:", err);
      alert(`Save failed: ${err}`);
    }
  }, []);

  const handleSaveAs = useCallback(async () => {
    try {
      const picked = await save({
        defaultPath: filePathRef.current ?? "untitled.md",
        filters: [{ name: "Markdown", extensions: ["md"] }],
      });
      const path = typeof picked === "string" ? picked : null;
      if (!path) return;
      await writeTextFile(path, currentMarkdownRef.current);
      setFilePath(path);
      setDirty(false);
    } catch (err) {
      console.error("save as failed:", err);
      alert(`Save As failed: ${err}`);
    }
  }, []);

  const handleToggleSidebar = useCallback(() => {
    setSidebarOpen((v) => !v);
  }, []);

  // listen to native menu events from Rust
  useEffect(() => {
    const unlistenPromise = listen<string>("menu", (event) => {
      switch (event.payload) {
        case "new":
          void handleNew();
          break;
        case "open_file":
          void handleOpenFile();
          break;
        case "open_folder":
          void handleOpenFolder();
          break;
        case "save":
          void handleSave();
          break;
        case "save_as":
          void handleSaveAs();
          break;
        case "toggle_sidebar":
          handleToggleSidebar();
          break;
        case "find":
        case "settings":
          // not implemented yet
          break;
      }
    });
    return () => {
      void unlistenPromise.then((fn) => fn());
    };
  }, [
    handleNew,
    handleOpenFile,
    handleOpenFolder,
    handleSave,
    handleSaveAs,
    handleToggleSidebar,
  ]);

  // sync window title with current file + dirty state
  useEffect(() => {
    const name = filePath ? filePath.split("/").pop() : "Untitled";
    const title = `${dirty ? "• " : ""}${name} — Marktext Next`;
    void getCurrentWindow().setTitle(title).catch(() => {});
  }, [filePath, dirty]);

  // intercept window close when there are unsaved changes
  useEffect(() => {
    const win = getCurrentWindow();
    const unlistenPromise = win.onCloseRequested(async (e) => {
      if (!dirtyRef.current) return;
      e.preventDefault();
      const ok = await ask("You have unsaved changes. Quit anyway?", {
        title: "Quit Marktext Next?",
        kind: "warning",
      });
      if (ok) {
        dirtyRef.current = false;
        await win.destroy();
      }
    });
    return () => {
      void unlistenPromise.then((fn) => fn());
    };
  }, []);

  return (
    <div className={`app${sidebarOpen ? "" : " sidebar-collapsed"}`}>
      {sidebarOpen && (
        <Sidebar
          folderPath={folderPath}
          activeFilePath={filePath}
          onSelectFile={handleSelectFromTree}
          onOpenFolder={handleOpenFolder}
        />
      )}
      <div className="main-pane">
        <header className="toolbar">
          <button
            className="icon-button"
            onClick={handleToggleSidebar}
            title="Toggle Sidebar (⌘\\)"
          >
            <SidebarIcon />
          </button>
          <span className="file-label" title={filePath ?? "Untitled"}>
            {dirty ? "• " : ""}
            {filePath ? filePath.split("/").pop() : "Untitled"}
          </span>
        </header>
        <main className="editor-pane">
          <Editor
            initialMarkdown={loadedMarkdown}
            onMarkdownChange={handleEditorChange}
          />
        </main>
      </div>
    </div>
  );
}

export default App;
