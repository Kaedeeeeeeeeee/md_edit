import { useEffect, useState } from "react";
import { readDir, type DirEntry } from "@tauri-apps/plugin-fs";
import {
  ChevronDownIcon,
  ChevronRightIcon,
  DocumentIcon,
  FolderIcon,
  FolderOpenIcon,
  PlusIcon,
} from "./icons";

interface FileNode {
  name: string;
  path: string;
  isDirectory: boolean;
  children?: FileNode[];
}

interface SidebarProps {
  folderPath: string | null;
  activeFilePath: string | null;
  onSelectFile: (path: string) => void;
  onOpenFolder: () => void;
}

const MD_EXTENSIONS = new Set(["md", "markdown", "mdown", "mkd"]);

function isMarkdown(name: string): boolean {
  const dot = name.lastIndexOf(".");
  if (dot < 0) return false;
  return MD_EXTENSIONS.has(name.slice(dot + 1).toLowerCase());
}

function stripExtension(name: string): string {
  return name.replace(/\.(md|markdown|mdown|mkd)$/i, "");
}

async function buildTree(folderPath: string): Promise<FileNode[]> {
  async function walk(dir: string): Promise<FileNode[]> {
    let entries: DirEntry[];
    try {
      entries = await readDir(dir);
    } catch (err) {
      console.warn("readDir failed:", dir, err);
      return [];
    }
    const nodes: FileNode[] = [];
    for (const entry of entries) {
      if (entry.name.startsWith(".")) continue;
      const path = `${dir}/${entry.name}`;
      if (entry.isDirectory) {
        const children = await walk(path);
        if (children.length > 0) {
          nodes.push({
            name: entry.name,
            path,
            isDirectory: true,
            children,
          });
        }
      } else if (isMarkdown(entry.name)) {
        nodes.push({
          name: entry.name,
          path,
          isDirectory: false,
        });
      }
    }
    nodes.sort((a, b) => {
      if (a.isDirectory !== b.isDirectory) return a.isDirectory ? -1 : 1;
      return a.name.localeCompare(b.name);
    });
    return nodes;
  }
  return walk(folderPath);
}

interface NodeRowProps {
  node: FileNode;
  depth: number;
  activeFilePath: string | null;
  onSelectFile: (path: string) => void;
}

function NodeRow({ node, depth, activeFilePath, onSelectFile }: NodeRowProps) {
  const [expanded, setExpanded] = useState(depth === 0);

  if (node.isDirectory) {
    return (
      <div className="tree-node">
        <button
          className="tree-row tree-folder"
          style={{ paddingLeft: 6 + depth * 16 }}
          onClick={() => setExpanded((v) => !v)}
        >
          <span className="tree-chev">
            {expanded ? <ChevronDownIcon /> : <ChevronRightIcon />}
          </span>
          <span className="tree-icon tree-icon-folder">
            {expanded ? <FolderOpenIcon /> : <FolderIcon />}
          </span>
          <span className="tree-name">{node.name}</span>
        </button>
        {expanded && node.children && (
          <div>
            {node.children.map((child) => (
              <NodeRow
                key={child.path}
                node={child}
                depth={depth + 1}
                activeFilePath={activeFilePath}
                onSelectFile={onSelectFile}
              />
            ))}
          </div>
        )}
      </div>
    );
  }

  const isActive = activeFilePath === node.path;
  return (
    <button
      className={`tree-row tree-file${isActive ? " is-active" : ""}`}
      style={{ paddingLeft: 6 + depth * 16 + 14 }}
      onClick={() => onSelectFile(node.path)}
      title={node.path}
    >
      <span className="tree-icon tree-icon-file">
        <DocumentIcon />
      </span>
      <span className="tree-name">{stripExtension(node.name)}</span>
    </button>
  );
}

export function Sidebar({
  folderPath,
  activeFilePath,
  onSelectFile,
  onOpenFolder,
}: SidebarProps) {
  const [tree, setTree] = useState<FileNode[] | null>(null);
  const [loading, setLoading] = useState(false);

  useEffect(() => {
    if (!folderPath) {
      setTree(null);
      return;
    }
    let cancelled = false;
    setLoading(true);
    void buildTree(folderPath)
      .then((nodes) => {
        if (!cancelled) setTree(nodes);
      })
      .catch((err) => {
        console.error("buildTree failed:", err);
        if (!cancelled) setTree([]);
      })
      .finally(() => {
        if (!cancelled) setLoading(false);
      });
    return () => {
      cancelled = true;
    };
  }, [folderPath]);

  const folderName = folderPath ? folderPath.split("/").pop() || folderPath : null;

  return (
    <aside className="sidebar">
      <div className="sidebar-header">
        <span className="sidebar-title">{folderName ?? "No folder"}</span>
        <button
          className="sidebar-action"
          onClick={onOpenFolder}
          title="Open folder…"
        >
          <PlusIcon />
        </button>
      </div>
      <div className="sidebar-body">
        {!folderPath && (
          <div className="sidebar-empty">
            <p>Open a folder to browse markdown files.</p>
            <button onClick={onOpenFolder}>Open Folder…</button>
          </div>
        )}
        {folderPath && loading && (
          <div className="sidebar-empty">Scanning…</div>
        )}
        {folderPath && !loading && tree && tree.length === 0 && (
          <div className="sidebar-empty">No markdown files found.</div>
        )}
        {folderPath && tree && tree.length > 0 && (
          <div className="tree">
            {tree.map((node) => (
              <NodeRow
                key={node.path}
                node={node}
                depth={0}
                activeFilePath={activeFilePath}
                onSelectFile={onSelectFile}
              />
            ))}
          </div>
        )}
      </div>
    </aside>
  );
}
