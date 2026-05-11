import SwiftUI

struct SidebarView: View {
    @Environment(DocumentStore.self) private var store

    var body: some View {
        @Bindable var store = store
        Group {
            if store.fileTree.isEmpty {
                EmptySidebar()
            } else {
                // Inline outline-aware List initializer.  Critical: selection
                // IDs are derived from the `id:` keypath here.  Using `\.url`
                // makes them URLs so the binding type lines up; manual `.tag()`
                // on rows wouldn't override this when OutlineGroup is involved.
                List(
                    store.fileTree,
                    id: \.url,
                    children: \.optionalChildren,
                    selection: Binding(
                        get: { store.currentFileURL },
                        set: { url in
                            guard let url else { return }
                            var isDir: ObjCBool = false
                            let exists = FileManager.default.fileExists(
                                atPath: url.path,
                                isDirectory: &isDir
                            )
                            if exists, !isDir.boolValue, url != store.currentFileURL {
                                store.loadFile(url)
                            }
                        }
                    )
                ) { node in
                    FileRow(node: node)
                        .contextMenu { rowMenu(for: node) }
                }
                .listStyle(.sidebar)
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

    @ViewBuilder
    private func rowMenu(for node: FileNode) -> some View {
        if node.isDirectory {
            Button("New File…") {
                store.createNewFile(in: node.url)
            }
            Button("New Folder…") {
                store.createNewFolder(in: node.url)
            }
            Divider()
        }
        Button("Reveal in Finder") {
            store.revealInFinder(node.url)
        }
        Divider()
        Button("Rename…") {
            store.rename(node.url)
        }
        Button("Move to Trash", role: .destructive) {
            store.delete(node.url)
        }
    }
}

private struct FileRow: View {
    let node: FileNode

    var body: some View {
        Label {
            Text(displayName)
                .lineLimit(1)
                .truncationMode(.middle)
        } icon: {
            Image(systemName: node.isDirectory ? "folder.fill" : "doc.text")
                .foregroundStyle(node.isDirectory ? Color.accentColor : .secondary)
        }
    }

    private var displayName: String {
        if node.isDirectory {
            return node.name
        }
        return node.name.replacingOccurrences(
            of: "\\.(md|markdown|mdown|mkd)$",
            with: "",
            options: .regularExpression
        )
    }
}

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
