import SwiftUI

struct SidebarView: View {
    @Environment(DocumentStore.self) private var store
    @State private var expanded: Set<URL> = []
    @State private var didAutoExpand = false
    @State private var recents: [(url: URL, displayName: String)] = WorkspaceBookmark.recentWorkspaces()

    /// Inline-rename target: NodeRow checks `renamingURL == node.url` to
    /// swap its Text for a TextField.  Only one row renames at a time.
    @State private var renamingURL: URL?

    /// Sidebar key-focus state.  Surfaced via `.focusedValue` so the
    /// menu-bar Cut/Copy/Paste/Delete commands know whether to route to
    /// the sidebar or fall through to the editor.
    @FocusState private var sidebarHasFocus: Bool

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
                .dropDestination(for: MultiFileTransfer.self) { items, _ in
                    guard let folder = store.folderURL else { return false }
                    let urls = items.flatMap { $0.urls }
                    cancelRenaming()
                    let moved = store.move(urls, into: folder)
                    return !moved.isEmpty
                }
            Divider()
            SidebarFooter(itemCount: visibleCount)
        }
        .frame(minWidth: 200, idealWidth: 260, maxWidth: 360)
        // Make the sidebar a key-focus target so .onKeyPress(.delete)
        // fires and the FocusedValue gate lights up for menu commands.
        .focusable(true, interactions: .activate)
        .focused($sidebarHasFocus)
        .focusedValue(\.sidebarFocused, sidebarHasFocus)
        .onKeyPress(.delete) {
            guard sidebarHasFocus, !store.selection.isEmpty else { return .ignored }
            store.deleteSelection()
            return .handled
        }
        .onChange(of: store.folderURL) { _, _ in
            recents = WorkspaceBookmark.recentWorkspaces()
            // Workspace switch → selection becomes meaningless.
            store.clearSelection()
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
                            expanded: $expanded,
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
                        expanded.insert(first.url)
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
        if store.clipboard != nil {
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
        store.flattenedVisibleURLs(expanded: expanded).count
    }

    private func cancelRenaming() {
        if renamingURL != nil { renamingURL = nil }
    }
}

// MARK: - Workspace header

private struct WorkspaceHeader: View {
    @Environment(DocumentStore.self) private var store
    @Binding var recents: [(url: URL, displayName: String)]

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
                Image(systemName: "books.vertical")
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
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
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
        HStack(spacing: 6) {
            Button {
                store.createNewFile(in: targetFolder())
            } label: {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.borderless)
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
            .buttonStyle(.borderless)
            .help("New Folder")
            .disabled(store.folderURL == nil)

            Button {
                store.openFolderDialog()
            } label: {
                Image(systemName: "folder")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.borderless)
            .help("Open / Switch Workspace…")

            Spacer()

            if itemCount > 0 {
                Text("\(itemCount) item\(itemCount == 1 ? "" : "s")")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
    }

    /// If exactly one folder is selected, new items go inside it.
    /// Otherwise they land at workspace root.
    private func targetFolder() -> URL? {
        guard store.selection.count == 1, let only = store.selection.first else {
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
    let node: FileNode
    let depth: Int
    @Binding var expanded: Set<URL>
    @Binding var renamingURL: URL?

    @State private var hovering = false
    @State private var dropTargeted = false
    @State private var editingName: String = ""
    @FocusState private var isRenameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            rowBody
            if node.isDirectory, expanded.contains(node.url) {
                ForEach(node.children) { child in
                    NodeRow(
                        node: child,
                        depth: depth + 1,
                        expanded: $expanded,
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
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(rowBackground)
        )
        .overlay(
            // Drop highlight: faint accent stroke when a drag is hovering
            // a folder row.
            RoundedRectangle(cornerRadius: 5)
                .strokeBorder(
                    dropTargeted ? Color.accentColor.opacity(0.6) : Color.clear,
                    lineWidth: 1.5
                )
        )
        .opacity(isCutPending ? 0.45 : 1.0)
        .contentShape(Rectangle())
        // Drag source: package the row's URL (and the rest of the
        // selection if this row is part of it) into a MultiFileTransfer.
        .draggable(transferPayload()) {
            // Drag preview rendered from the URL list rather than the
            // live row, so LazyVStack-scrolled-out previews still draw.
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
            Image(systemName: expanded.contains(node.url) ? "chevron.down" : "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 12, alignment: .center)
        } else {
            Color.clear.frame(width: 12, height: 12)
        }
    }

    @ViewBuilder
    private var icon: some View {
        Image(systemName: node.isDirectory ? "folder.fill" : "doc.text")
            .foregroundStyle(node.isDirectory ? Color.accentColor : .secondary)
            .font(.system(size: 13))
            .frame(width: 16, alignment: .center)
    }

    /// Background colour layering:
    ///   - Active editor file: existing quaternary gray
    ///   - In multi-selection: faint accent
    ///   - Hovered: faint gray
    /// They stack additively when overlapping.
    private var rowBackground: Color {
        if isSelected {
            return Color.accentColor.opacity(0.18)
        }
        if !node.isDirectory, store.currentFileURL?.standardizedFileURL == node.url.standardizedFileURL {
            return Color(nsColor: .quaternaryLabelColor).opacity(0.9)
        }
        if !node.isDirectory, hovering {
            return Color(nsColor: .quaternaryLabelColor).opacity(0.5)
        }
        return .clear
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
        store.selection.contains(node.url.standardizedFileURL)
    }

    private var isCutPending: Bool {
        guard let clip = store.clipboard, clip.op == .cut else { return false }
        return clip.urls.contains { $0.standardizedFileURL == node.url.standardizedFileURL }
    }

    private var isRenaming: Bool {
        renamingURL == node.url
    }

    // MARK: - Interaction

    private func handleSingleTap(modifiers: EventModifiers) {
        // Don't intercept clicks while we're renaming this row.
        if isRenaming { return }
        if modifiers.contains(.command) {
            store.toggleSelection(node.url)
            return
        }
        if modifiers.contains(.shift) {
            let visible = store.flattenedVisibleURLs(expanded: expanded)
            store.extendSelection(to: node.url, visibleOrder: visible)
            return
        }
        // Plain tap.
        if node.isDirectory {
            if expanded.contains(node.url) {
                expanded.remove(node.url)
            } else {
                expanded.insert(node.url)
            }
            store.selectOnly(node.url, loadIfFile: false)
        } else {
            store.selectOnly(node.url, loadIfFile: true)
        }
    }

    private func transferPayload() -> MultiFileTransfer {
        // If the dragged row is part of the multi-selection, ship the
        // whole selection.  Otherwise reset selection to just this row
        // and ship that — mirrors Finder.
        let std = node.url.standardizedFileURL
        if store.selection.contains(std) {
            return MultiFileTransfer(urls: Array(store.selection))
        }
        store.selectOnly(node.url, loadIfFile: false)
        return MultiFileTransfer(urls: [node.url])
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
            if store.selection.contains(node.url.standardizedFileURL),
               store.selection.count > 1 {
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
            content.dropDestination(for: MultiFileTransfer.self) { items, _ in
                let urls = items.flatMap { $0.urls }
                onDropStart()
                let moved = store.move(urls, into: node.url)
                return !moved.isEmpty
            } isTargeted: { dropTargeted = $0 }
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
            Text("Click ✎ or 📁+ below to create one")
                .font(.caption)
                .foregroundStyle(.tertiary)
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
