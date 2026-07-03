import SwiftUI

struct SidebarView: View {
    @Environment(DocumentStore.self) private var store
    @State private var didAutoExpand = false
    @State private var recents: [(url: URL, displayName: String)] = WorkspaceBookmark.recentWorkspaces()

    /// Inline-rename target: NodeRow checks `renamingURL == node.url` to
    /// swap its Text for a TextField.  Only one row renames at a time.
    @State private var renamingURL: URL?

    /// AppKit responder backing for the file tree.  Row taps promote it to
    /// first responder so the standard Edit-menu file commands light up.
    @State private var responderHandle = SidebarResponderHandle()

    var body: some View {
        VStack(spacing: 0) {
            WorkspaceHeader(recents: $recents)
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // Right-click on empty background → workspace-root actions.
                // Per-row `.contextMenu` on NodeRow wins on row hits.
                .contextMenu {
                    rootContextMenu
                }
                // Drop target for the workspace root.  Drag a row from a
                // folder out onto this area to move it up to the root.
                .dropDestination(for: URL.self) { urls, _ in
                    DebugLog.write("[drag] root drop urls=\(urls.count)")
                    guard let folder = store.folderURL else { return false }
                    cancelRenaming()
                    let moved = store.move(urls, into: folder)
                    return !moved.isEmpty
                }
            Divider()
            SidebarFooter(itemCount: visibleCount)
        }
        .frame(minWidth: 200, idealWidth: 260, maxWidth: 360)
        // AppKit responder backing: claims first-responder on row tap /
        // empty-area click so the standard Edit menu routes Cut/Copy/Paste/
        // Delete (and the ⌫ key) to file ops, and yields to the editor's
        // WKWebView when the editor is focused.
        .background(SidebarResponder(store: store, handle: responderHandle))
        .environment(\.sidebarResponderHandle, responderHandle)
        .onChange(of: store.folderURL) { _, _ in
            recents = WorkspaceBookmark.recentWorkspaces()
            // Workspace switch → selection becomes meaningless.
            store.sidebar.clear()
            renamingURL = nil
        }
    }

    @ViewBuilder
    private var content: some View {
        if store.fileTree.isEmpty {
            EmptySidebar()
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(store.fileTree) { node in
                        NodeRow(
                            node: node,
                            depth: 0,
                            renamingURL: $renamingURL
                        )
                    }
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 6)
            }
            .onAppear {
                if !didAutoExpand {
                    didAutoExpand = true
                    // Open the first folder so the tree isn't an empty wall on launch.
                    if let first = store.fileTree.first(where: \.isDirectory) {
                        store.sidebar.expanded.insert(first.url)
                    }
                }
            }
        }
    }

    /// Right-click-on-empty-sidebar menu: workspace-root actions.
    @ViewBuilder
    private var rootContextMenu: some View {
        Button("New File at root") { store.createNewFile() }
            .disabled(store.folderURL == nil)
        Button("New Folder at root") { store.createNewFolder() }
            .disabled(store.folderURL == nil)
        if store.sidebar.clipboard != nil {
            Divider()
            Button("Paste") { store.paste(into: nil) }
        }
        Divider()
        if let folder = store.folderURL {
            Button("Reveal Workspace in Finder") {
                store.revealInFinder(folder)
            }
        }
    }

    private var visibleCount: Int {
        store.flattenedVisibleURLs().count
    }

    private func cancelRenaming() {
        if renamingURL != nil { renamingURL = nil }
    }
}

// MARK: - Workspace header

private struct WorkspaceHeader: View {
    @Environment(DocumentStore.self) private var store
    @Binding var recents: [(url: URL, displayName: String)]
    @State private var hovering = false

    var body: some View {
        Menu {
            ForEach(menuRows, id: \.url.absoluteString) { entry in
                Button {
                    guard entry.url != store.folderURL else { return }
                    store.adoptRecentWorkspace(entry.url)
                } label: {
                    HStack {
                        Image(systemName: entry.url == store.folderURL
                              ? "checkmark.circle.fill"
                              : "folder")
                        VStack(alignment: .leading) {
                            Text(entry.displayName)
                            Text(entry.url.path)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }
            }
            Divider()
            Button {
                store.openFolderDialog()
            } label: {
                Label("Add Folder as Workspace…", systemImage: "folder.badge.plus")
            }
            if let folder = store.folderURL {
                Button {
                    store.revealInFinder(folder)
                } label: {
                    Label("Reveal in Finder", systemImage: "arrow.up.right.square")
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "rectangle.stack.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.accentColor)
                Text(currentDisplayName)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            // Hover wash matching the file rows' faint gray — without it
            // the header gives no hint that it's clickable at all.
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(hovering
                          ? Color(nsColor: .quaternaryLabelColor).opacity(0.5)
                          : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .onHover { hovering = $0 }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
    }

    private var currentDisplayName: String {
        store.folderURL?.lastPathComponent ?? "No workspace"
    }

    /// Recents with the active workspace pinned at the top, even if it
    /// wasn't yet in the recents list (first-launch onboarding flow).
    private var menuRows: [(url: URL, displayName: String)] {
        var rows = recents
        if let active = store.folderURL,
           !rows.contains(where: { $0.url == active }) {
            rows.insert((url: active, displayName: active.lastPathComponent), at: 0)
        }
        return rows
    }
}

// MARK: - Sidebar footer (action bar)

/// Pinned at the bottom of the sidebar, Apple-Notes / Xcode style.
/// Holds the global file-management actions that used to live in the
/// window title bar.  Keeping them here makes them visually part of the
/// file-tree affordance and frees the title bar for document-level
/// actions only (Save).
private struct SidebarFooter: View {
    @Environment(DocumentStore.self) private var store
    let itemCount: Int

    var body: some View {
        // Two actions only: New File / New Folder.  Workspace switching
        // used to have a third button here but it duplicated the header
        // menu (and the File menu's ⌘⌥O) — removed so the bar reads as
        // "create things", full stop.
        HStack(spacing: 6) {
            Button {
                store.createNewFile(in: targetFolder())
            } label: {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.accessoryBar)
            .help("New File")
            .disabled(store.folderURL == nil)

            Button {
                store.createNewFolder(in: targetFolder())
            } label: {
                Image(systemName: "folder.badge.plus")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.accessoryBar)
            .help("New Folder")
            .disabled(store.folderURL == nil)

            Spacer()

            if itemCount > 0 {
                Text(countText)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
    }

    private var countText: String {
        itemCount == 1
            ? String(localized: "1 item")
            : String(format: String(localized: "%d items"), itemCount)
    }

    /// If exactly one folder is selected, new items go inside it.
    /// Otherwise they land at workspace root.
    private func targetFolder() -> URL? {
        guard store.sidebar.selection.count == 1,
              let only = store.sidebar.selection.first else {
            return nil
        }
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: only.path, isDirectory: &isDir),
           isDir.boolValue {
            return only
        }
        return nil
    }
}

// MARK: - Recursive node row

private struct NodeRow: View {
    @Environment(DocumentStore.self) private var store
    @Environment(\.sidebarResponderHandle) private var responderHandle
    let node: FileNode
    let depth: Int
    @Binding var renamingURL: URL?

    @State private var hovering = false
    @State private var dropTargeted = false
    @State private var editingName: String = ""
    @FocusState private var isRenameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            rowBody
            if node.isDirectory, isExpanded {
                ForEach(node.children) { child in
                    NodeRow(
                        node: child,
                        depth: depth + 1,
                        renamingURL: $renamingURL
                    )
                }
            }
        }
    }

    @ViewBuilder
    private var rowBody: some View {
        HStack(spacing: 4) {
            chevron
            icon
            if isRenaming {
                renameField
            } else {
                Text(displayName)
                    .font(.system(size: 13))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, CGFloat(depth) * 14 + 4)
        .padding(.trailing, 6)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(rowBackground)
        )
        .overlay(
            // Drop highlight: faint accent stroke when a drag is hovering
            // a folder row.  Accent is fine here — it's a transient action
            // state, not a persistent selection.
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(
                    dropTargeted ? Color.accentColor.opacity(0.6) : Color.clear,
                    lineWidth: 1.5
                )
        )
        .opacity(isCutPending ? 0.45 : 1.0)
        .contentShape(Rectangle())
        // Drag source.  Use the row's URL directly — SwiftUI's
        // Transferable conformance for URL gives us reliable intra-app
        // decoding AND drag-out-to-Finder for free.  Multi-selection
        // drag (carrying N URLs in one drag op) requires NSItemProvider
        // and is deferred — for v1, multi-drag falls back to dragging
        // just the row the user grabbed.
        .draggable(dragURL()) {
            HStack(spacing: 6) {
                Image(systemName: node.isDirectory ? "folder.fill" : "doc.text")
                Text(displayName)
                    .font(.system(size: 13))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 6))
        }
        // Drop destination: folders accept drops, files don't.
        // For folder rows, isTargeted lights up the overlay accent ring.
        .modifier(FolderDropDestination(
            node: node,
            store: store,
            dropTargeted: $dropTargeted,
            onDropStart: cancelRenaming
        ))
        .contextMenu { rowMenu }
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) {
            // Double-click on the row name → enter rename mode.
            if !node.isDirectory {
                beginRenaming()
            } else {
                // For folders, double-click toggles expansion (same as single).
                handleSingleTap(modifiers: .init())
            }
        }
        .simultaneousGesture(
            // Single-click handler runs only if the double-click hasn't
            // already claimed the gesture.  We listen for modifier keys
            // so ⌘+click toggles, Shift+click ranges.
            TapGesture(count: 1).modifiers(.command).onEnded {
                handleSingleTap(modifiers: .command)
            }
        )
        .simultaneousGesture(
            TapGesture(count: 1).modifiers(.shift).onEnded {
                handleSingleTap(modifiers: .shift)
            }
        )
        .simultaneousGesture(
            TapGesture(count: 1).onEnded {
                handleSingleTap(modifiers: .init())
            }
        )
    }

    @ViewBuilder
    private var renameField: some View {
        TextField("", text: $editingName)
            .font(.system(size: 13))
            .textFieldStyle(.plain)
            .focused($isRenameFocused)
            .onAppear {
                // Pre-fill full filename incl. extension; macOS will
                // place the caret at end by default.  Select-stem-only
                // would require dropping into AppKit (NSTextField) so
                // we accept caret-at-end for v1.
                editingName = node.name
                isRenameFocused = true
            }
            .onSubmit { commitRename() }
            .onChange(of: isRenameFocused) { _, focused in
                if !focused, renamingURL == node.url {
                    commitRename()
                }
            }
            .onKeyPress(.escape) {
                cancelRenaming()
                return .handled
            }
    }

    @ViewBuilder
    private var chevron: some View {
        if node.isDirectory {
            // One glyph rotating in place (not a right/down symbol swap) so
            // the disclosure animates like a native outline view.
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .animation(.easeOut(duration: 0.15), value: isExpanded)
                .frame(width: 12, alignment: .center)
        } else {
            Color.clear.frame(width: 12, height: 12)
        }
    }

    @ViewBuilder
    private var icon: some View {
        Image(systemName: iconName)
            .foregroundStyle(node.isDirectory ? Color.accentColor : .secondary)
            .font(.system(size: 13))
            .frame(width: 16, alignment: .center)
    }

    private var iconName: String {
        if node.isDirectory { return "folder.fill" }
        return isOpenDocument ? "doc.text.fill" : "doc.text"
    }

    /// Background colour layering — deliberately all-gray. The selection
    /// language of this sidebar is achromatic (Notes-style); accent colour
    /// is reserved for folder glyphs and the transient drop ring.
    /// First match wins:
    ///   - Selected (single or ⌘/Shift multi): the system's "unemphasized"
    ///     selection gray — what native list views show when not key.
    ///     Adapts to dark mode for free.
    ///   - Open in editor but selection elsewhere: weaker quaternary gray.
    ///   - Hovered: faintest gray.
    private var rowBackground: Color {
        if isSelected {
            return Color(nsColor: .unemphasizedSelectedContentBackgroundColor)
        }
        if isOpenDocument {
            return Color(nsColor: .quaternaryLabelColor).opacity(0.9)
        }
        if !node.isDirectory, hovering {
            return Color(nsColor: .quaternaryLabelColor).opacity(0.5)
        }
        return .clear
    }

    /// True when this row's file is the document open in the editor.
    /// Drives both the stronger background and the filled glyph, so the
    /// open document stays identifiable after the selection highlight
    /// moves elsewhere (⌘-click, folder click).
    private var isOpenDocument: Bool {
        !node.isDirectory
            && store.currentFileURL?.standardizedFileURL == node.url.standardizedFileURL
    }

    private var displayName: String {
        if node.isDirectory { return node.name }
        return node.name.replacingOccurrences(
            of: "\\.(md|markdown|mdown|mkd)$",
            with: "",
            options: .regularExpression
        )
    }

    private var isSelected: Bool {
        store.sidebar.selection.contains(node.url.standardizedFileURL)
    }

    private var isCutPending: Bool {
        guard let clip = store.sidebar.clipboard, clip.op == .cut else { return false }
        return clip.urls.contains { $0.standardizedFileURL == node.url.standardizedFileURL }
    }

    private var isRenaming: Bool {
        renamingURL == node.url
    }

    private var isExpanded: Bool {
        store.sidebar.expanded.contains(node.url)
    }

    // MARK: - Interaction

    private func handleSingleTap(modifiers: EventModifiers) {
        // Don't intercept clicks while we're renaming this row.
        if isRenaming { return }
        // Promote the sidebar to first responder so Edit-menu Cut/Copy/
        // Paste/Delete validate against this selection.
        responderHandle.makeKey()
        if modifiers.contains(.command) {
            store.sidebar.toggle(node.url)
            return
        }
        if modifiers.contains(.shift) {
            store.sidebar.extend(to: node.url, visibleOrder: store.flattenedVisibleURLs())
            return
        }
        // Plain tap.
        if node.isDirectory {
            if isExpanded {
                store.sidebar.expanded.remove(node.url)
            } else {
                store.sidebar.expanded.insert(node.url)
            }
            store.selectOnly(node.url, loadIfFile: false)
        } else {
            store.selectOnly(node.url, loadIfFile: true)
        }
    }

    private func dragURL() -> URL {
        // Single-URL drag.  Updates selection to this row only (matches
        // Finder) so the visual highlight tracks what's actually being
        // dragged.
        let std = node.url.standardizedFileURL
        if !store.sidebar.selection.contains(std) {
            store.selectOnly(node.url, loadIfFile: false)
        }
        DebugLog.write("[drag] start url=\(node.url.lastPathComponent)")
        return node.url
    }

    private func beginRenaming() {
        renamingURL = node.url
        editingName = node.name
    }

    private func cancelRenaming() {
        if renamingURL == node.url {
            renamingURL = nil
            editingName = ""
        }
    }

    private func commitRename() {
        guard renamingURL == node.url else { return }
        let proposed = editingName.trimmingCharacters(in: .whitespacesAndNewlines)
        defer {
            renamingURL = nil
            editingName = ""
        }
        guard !proposed.isEmpty, proposed != node.name else { return }
        _ = store.rename(node.url, to: proposed)
    }

    @ViewBuilder
    private var rowMenu: some View {
        if node.isDirectory {
            Button("New File…") { store.createNewFile(in: node.url) }
            Button("New Folder…") { store.createNewFolder(in: node.url) }
            Divider()
        }
        Button("Reveal in Finder") { store.revealInFinder(node.url) }
        Divider()
        Button("Rename") { beginRenaming() }
            .keyboardShortcut(.return, modifiers: [])
        Button("Move to Trash", role: .destructive) {
            // If this row is part of a multi-selection, delete the whole
            // selection; otherwise just this row.
            if store.sidebar.selection.contains(node.url.standardizedFileURL),
               store.sidebar.selection.count > 1 {
                store.deleteSelection()
            } else {
                store.delete(node.url)
            }
        }
    }
}

/// View modifier that wraps `dropDestination` so we only attach it to
/// folder rows (files can't be drop targets in our model).  Keeps
/// NodeRow's modifier chain readable.
private struct FolderDropDestination: ViewModifier {
    let node: FileNode
    let store: DocumentStore
    @Binding var dropTargeted: Bool
    let onDropStart: () -> Void

    func body(content: Content) -> some View {
        if node.isDirectory {
            content.dropDestination(for: URL.self) { urls, _ in
                DebugLog.write("[drag] folder “\(node.name)” drop urls=\(urls.count)")
                onDropStart()
                let moved = store.move(urls, into: node.url)
                return !moved.isEmpty
            } isTargeted: { isTargeted in
                if isTargeted { DebugLog.write("[drag] hover over folder “\(node.name)”") }
                dropTargeted = isTargeted
            }
        } else {
            content
        }
    }
}

// MARK: - Empty state

private struct EmptySidebar: View {
    @Environment(DocumentStore.self) private var store

    var body: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "doc.text")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(.tertiary)
            Text("No notes yet")
                .font(.callout)
                .foregroundStyle(.secondary)
            // Direct affordance instead of a caption pointing at the
            // footer buttons.
            Button("New File") {
                store.createNewFile()
            }
            .controlSize(.small)
            .disabled(store.folderURL == nil)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding()
    }
}

extension FileNode {
    var optionalChildren: [FileNode]? {
        isDirectory ? children : nil
    }
}
