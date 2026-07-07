import SwiftUI

struct SidebarView: View {
    @Environment(AppModel.self) private var store
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
            VStack(spacing: 8) {
                WorkspaceHeader(recents: $recents)
                SidebarQuickActions()
            }
            .padding(.horizontal, 8)
            .padding(.top, 8)
            .padding(.bottom, 8)

            Divider().opacity(0.65)

            VStack(spacing: 0) {
                SidebarSectionHeader(itemCount: visibleCount)
                content
            }
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
                    guard let folder = store.workspace.folderURL else { return false }
                    cancelRenaming()
                    let moved = store.move(urls, into: folder)
                    return !moved.isEmpty
                }

            Divider().opacity(0.65)
            SidebarFooter(itemCount: visibleCount)
        }
        .frame(minWidth: 220, idealWidth: 280, maxWidth: 380)
        // AppKit responder backing: claims first-responder on row tap /
        // empty-area click so the standard Edit menu routes Cut/Copy/Paste/
        // Delete (and the ⌫ key) to file ops, and yields to the editor's
        // WKWebView when the editor is focused.
        .background(SidebarResponder(store: store, handle: responderHandle))
        .environment(\.sidebarResponderHandle, responderHandle)
        .onChange(of: store.workspace.folderURL) { _, _ in
            recents = WorkspaceBookmark.recentWorkspaces()
            // Workspace switch → selection becomes meaningless.
            store.sidebar.clear()
            renamingURL = nil
        }
    }

    @ViewBuilder
    private var content: some View {
        if store.workspace.fileTree.isEmpty {
            EmptySidebar()
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(store.workspace.fileTree) { node in
                        NodeRow(
                            node: node,
                            depth: 0,
                            renamingURL: $renamingURL
                        )
                    }
                }
                .padding(.top, 2)
                .padding(.bottom, 8)
                .padding(.horizontal, 6)
            }
            .onAppear {
                if !didAutoExpand {
                    didAutoExpand = true
                    // Open the first folder so the tree isn't an empty wall on launch.
                    if let first = store.workspace.fileTree.first(where: \.isDirectory) {
                        store.sidebar.expanded.insert(first.url)
                    }
                }
            }
        }
    }

    /// Right-click-on-empty-sidebar menu: workspace-root actions.
    @ViewBuilder
    private var rootContextMenu: some View {
        Button("New Page") { store.createNewFile() }
            .disabled(store.workspace.folderURL == nil)
        Button("New Folder") { store.createNewFolder() }
            .disabled(store.workspace.folderURL == nil)
        if store.sidebar.clipboard != nil {
            Divider()
            Button("Paste") { store.paste(into: nil) }
        }
        Divider()
        if let folder = store.workspace.folderURL {
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
    @Environment(AppModel.self) private var store
    @Binding var recents: [(url: URL, displayName: String)]
    @State private var hovering = false
    @State private var showingSwitcher = false

    var body: some View {
        Button {
            showingSwitcher.toggle()
        } label: {
            HStack(spacing: 9) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.accentColor.opacity(0.14))
                    Text(workspaceInitial)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }
                .frame(width: 28, height: 28)

                VStack(alignment: .leading, spacing: 1) {
                    Text(currentDisplayName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let currentPath {
                        Text(currentPath)
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }

                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(hovering
                          ? Color(nsColor: .quaternaryLabelColor).opacity(0.55)
                          : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel("Switch Workspace")
        .frame(maxWidth: .infinity, alignment: .leading)
        .popover(isPresented: $showingSwitcher, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(menuRows, id: \.url.absoluteString) { entry in
                    WorkspaceSwitcherRow(
                        entry: entry,
                        isActive: entry.url == store.workspace.folderURL
                    ) {
                        showingSwitcher = false
                        guard entry.url != store.workspace.folderURL else { return }
                        store.adoptRecentWorkspace(entry.url)
                    }
                }

                Divider()

                Button {
                    showingSwitcher = false
                    store.openFolderDialog()
                } label: {
                    Label("Add Folder as Workspace…", systemImage: "folder.badge.plus")
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 6)
                .padding(.vertical, 5)

                if let folder = store.workspace.folderURL {
                    Button {
                        showingSwitcher = false
                        store.revealInFinder(folder)
                    } label: {
                        Label("Reveal in Finder", systemImage: "arrow.up.right.square")
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 5)
                }
            }
            .padding(8)
            .frame(width: 320, alignment: .leading)
        }
    }

    private var currentDisplayName: String {
        store.workspace.folderURL?.lastPathComponent ?? "No workspace"
    }

    private var currentPath: String? {
        guard let folder = store.workspace.folderURL else { return nil }
        return folder.deletingLastPathComponent().path
    }

    private var workspaceInitial: String {
        guard let first = currentDisplayName.trimmingCharacters(in: .whitespacesAndNewlines).first else {
            return "N"
        }
        return String(first).uppercased()
    }

    /// Recents with the active workspace pinned at the top, even if it
    /// wasn't yet in the recents list (first-launch onboarding flow).
    private var menuRows: [(url: URL, displayName: String)] {
        var rows = recents
        if let active = store.workspace.folderURL,
           !rows.contains(where: { $0.url == active }) {
            rows.insert((url: active, displayName: active.lastPathComponent), at: 0)
        }
        return rows
    }
}

private struct WorkspaceSwitcherRow: View {
    let entry: (url: URL, displayName: String)
    let isActive: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: isActive ? "checkmark.circle.fill" : "folder")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(isActive ? Color.accentColor : .secondary)
                    .frame(width: 18, alignment: .center)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.displayName)
                        .font(.system(size: 13, weight: isActive ? .semibold : .regular))
                        .lineLimit(1)
                    Text(entry.url.path)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(hovering
                          ? Color(nsColor: .quaternaryLabelColor).opacity(0.55)
                          : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: - Sidebar top actions

private struct SidebarQuickActions: View {
    @Environment(AppModel.self) private var store

    var body: some View {
        VStack(spacing: 2) {
            SidebarActionRow(
                title: "New page",
                systemImage: "square.and.pencil",
                disabled: store.workspace.folderURL == nil
            ) {
                store.createNewFile(in: selectedFolderURL(in: store))
            }

            SidebarActionRow(
                title: "New folder",
                systemImage: "folder.badge.plus",
                disabled: store.workspace.folderURL == nil
            ) {
                store.createNewFolder(in: selectedFolderURL(in: store))
            }
        }
    }
}

private struct SidebarActionRow: View {
    let title: LocalizedStringKey
    let systemImage: String
    let disabled: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, alignment: .center)
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(hovering
                          ? Color(nsColor: .quaternaryLabelColor).opacity(0.45)
                          : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.45 : 1)
        .onHover { hovering = $0 }
        .accessibilityLabel(Text(title))
    }
}

// MARK: - Pages section header

private struct SidebarSectionHeader: View {
    @Environment(AppModel.self) private var store
    let itemCount: Int

    var body: some View {
        HStack(spacing: 6) {
            Text("Pages")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            if itemCount > 0 {
                Text("\(itemCount)")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 0)

            Menu {
                Button("New Page") { store.createNewFile() }
                Button("New Folder") { store.createNewFolder() }
                Divider()
                if let folder = store.workspace.folderURL {
                    Button("Reveal Workspace in Finder") {
                        store.revealInFinder(folder)
                    }
                }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .disabled(store.workspace.folderURL == nil)
            .help("Add at workspace root")
            .accessibilityLabel("Add Page or Folder")
        }
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .padding(.top, 10)
        .padding(.bottom, 4)
    }
}

// MARK: - Sidebar footer (action bar)

/// Pinned at the bottom of the sidebar, Apple-Notes / Xcode style.
/// Keeps status and paste affordances close to the tree without competing
/// with the main creation actions above the Pages section.
private struct SidebarFooter: View {
    @Environment(AppModel.self) private var store
    let itemCount: Int

    var body: some View {
        HStack(spacing: 8) {
            if let clipboard = store.sidebar.clipboard {
                Label(clipboardText(for: clipboard), systemImage: clipboardIcon(for: clipboard))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Button("Paste") {
                    store.paste(into: nil)
                }
                .buttonStyle(.link)
                .font(.system(size: 11, weight: .medium))
            } else {
                Image(systemName: "doc.text")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                Text(countText)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 0)

            Button {
                if let folder = store.workspace.folderURL {
                    store.revealInFinder(folder)
                }
            } label: {
                Image(systemName: "arrow.up.right.square")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .help("Reveal Workspace in Finder")
            .accessibilityLabel("Reveal Workspace in Finder")
            .disabled(store.workspace.folderURL == nil)
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

    private func clipboardText(for clipboard: SidebarClipboard) -> String {
        let count = clipboard.urls.count
        let noun = count == 1 ? String(localized: "item") : String(localized: "items")
        switch clipboard.op {
        case .cut:
            return String(format: String(localized: "Cut %d %@"), count, noun)
        case .copy:
            return String(format: String(localized: "Copied %d %@"), count, noun)
        }
    }

    private func clipboardIcon(for clipboard: SidebarClipboard) -> String {
        switch clipboard.op {
        case .cut: return "scissors"
        case .copy: return "doc.on.doc"
        }
    }
}

// MARK: - Recursive node row

private struct NodeRow: View {
    @Environment(AppModel.self) private var store
    @Environment(\.sidebarResponderHandle) private var responderHandle
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
        HStack(spacing: 6) {
            chevron
            icon
            if isRenaming {
                renameField
            } else {
                Text(displayName)
                    .font(.system(size: 13, weight: rowTextWeight))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
            trailingStatus
        }
        .padding(.leading, CGFloat(depth) * 16 + 8)
        .padding(.trailing, 6)
        .frame(height: 28)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(rowBackground)
        )
        .overlay(
            // Drop highlight: faint accent stroke when a drag is hovering
            // a folder row.  Accent is fine here — it's a transient action
            // state, not a persistent selection.
            RoundedRectangle(cornerRadius: 7, style: .continuous)
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
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
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
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovering)
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
                .foregroundStyle(.tertiary)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: isExpanded)
                .frame(width: 12, alignment: .center)
        } else {
            Color.clear.frame(width: 12, height: 12)
        }
    }

    @ViewBuilder
    private var icon: some View {
        Image(systemName: iconName)
            .foregroundStyle(iconColor)
            .font(.system(size: 13))
            .frame(width: 16, alignment: .center)
    }

    @ViewBuilder
    private var trailingStatus: some View {
        if isCutPending {
            Image(systemName: "scissors")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.tertiary)
        } else if isOpenDocument {
            Circle()
                .fill(Color.accentColor.opacity(0.8))
                .frame(width: 5, height: 5)
                .padding(.trailing, 4)
                .accessibilityHidden(true)
        }
    }

    private var iconName: String {
        if node.isDirectory { return isExpanded ? "folder.fill" : "folder" }
        return isOpenDocument ? "doc.text.fill" : "doc.text"
    }

    private var iconColor: Color {
        if isSelected || isOpenDocument { return Color.primary.opacity(0.72) }
        if node.isDirectory { return Color(nsColor: .secondaryLabelColor) }
        return Color(nsColor: .tertiaryLabelColor)
    }

    private var rowTextWeight: Font.Weight {
        isSelected || isOpenDocument ? .medium : .regular
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
        if dropTargeted {
            return Color.accentColor.opacity(0.10)
        }
        if isSelected {
            return Color(nsColor: .unemphasizedSelectedContentBackgroundColor)
        }
        if isOpenDocument {
            return Color(nsColor: .quaternaryLabelColor).opacity(0.75)
        }
        if hovering {
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
            && store.document.currentFileURL?.standardizedFileURL == node.url.standardizedFileURL
    }

    private var displayName: String {
        if node.isDirectory { return node.name }
        if isOpenDocument, let liveTitle = MarkdownDocumentTitle.title(fromMarkdown: store.document.currentMarkdown) {
            return liveTitle
        }
        if let documentTitle = node.documentTitle {
            return documentTitle
        }
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
    let store: AppModel
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
    @Environment(AppModel.self) private var store

    var body: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "doc.badge.plus")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.tertiary)
            Text("No pages")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
            Button {
                store.createNewFile()
            } label: {
                Label("New page", systemImage: "square.and.pencil")
                    .font(.system(size: 12, weight: .medium))
            }
            .controlSize(.small)
            .disabled(store.workspace.folderURL == nil)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding()
    }
}

@MainActor
private func selectedFolderURL(in store: AppModel) -> URL? {
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

extension FileNode {
    var optionalChildren: [FileNode]? {
        isDirectory ? children : nil
    }
}
