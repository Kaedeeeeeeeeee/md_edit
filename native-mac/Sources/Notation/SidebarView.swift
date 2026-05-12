import SwiftUI

struct SidebarView: View {
    @Environment(DocumentStore.self) private var store
    @State private var expanded: Set<URL> = []
    @State private var didAutoExpand = false

    var body: some View {
        Group {
            if store.fileTree.isEmpty {
                EmptySidebar()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(store.fileTree) { node in
                            NodeRow(
                                node: node,
                                depth: 0,
                                expanded: $expanded
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
        .frame(minWidth: 180, idealWidth: 240, maxWidth: 360)
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button {
                    store.createNewFile()
                } label: {
                    Image(systemName: "square.and.pencil")
                }
                .help("New File in workspace")
                .disabled(store.folderURL == nil)

                Button {
                    store.openFolderDialog()
                } label: {
                    Image(systemName: "folder.badge.plus")
                }
                .help("Open Folder")
            }
        }
    }
}

// MARK: - Recursive node row

private struct NodeRow: View {
    @Environment(DocumentStore.self) private var store
    let node: FileNode
    let depth: Int
    @Binding var expanded: Set<URL>

    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            rowButton
            if node.isDirectory, expanded.contains(node.url) {
                ForEach(node.children) { child in
                    NodeRow(node: child, depth: depth + 1, expanded: $expanded)
                }
            }
        }
    }

    @ViewBuilder
    private var rowButton: some View {
        Button(action: handleTap) {
            HStack(spacing: 4) {
                chevron
                icon
                Text(displayName)
                    .font(.system(size: 13))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
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
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu { rowMenu }
        .onHover { hovering = $0 }
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

    /// Files get a gray background when active (current file in editor) or
    /// hovered.  Folders never get a sticky background — they only respond
    /// to clicks by toggling expansion.
    private var rowBackground: Color {
        if !node.isDirectory, store.currentFileURL == node.url {
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

    private func handleTap() {
        if node.isDirectory {
            if expanded.contains(node.url) {
                expanded.remove(node.url)
            } else {
                expanded.insert(node.url)
            }
        } else {
            if store.currentFileURL != node.url {
                store.loadFile(node.url)
            }
        }
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
        Button("Rename…") { store.rename(node.url) }
        Button("Move to Trash", role: .destructive) { store.delete(node.url) }
    }
}

// MARK: - Empty state

private struct EmptySidebar: View {
    @Environment(DocumentStore.self) private var store

    var body: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "folder")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(.tertiary)
            Text("No folder open")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("Open Folder…") {
                store.openFolderDialog()
            }
            .buttonStyle(.bordered)
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
