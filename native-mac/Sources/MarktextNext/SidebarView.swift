import SwiftUI

struct SidebarView: View {
    @Environment(DocumentStore.self) private var store

    var body: some View {
        @Bindable var store = store
        Group {
            if store.fileTree.isEmpty {
                EmptySidebar()
            } else {
                List(selection: Binding(
                    get: { store.currentFileURL },
                    set: { url in
                        if let url, url != store.currentFileURL {
                            store.loadFile(url)
                        }
                    }
                )) {
                    OutlineGroup(store.fileTree, id: \.id, children: \.optionalChildren) { node in
                        FileRow(node: node)
                            .tag(node.isDirectory ? nil : node.url)
                    }
                }
                .listStyle(.sidebar)
            }
        }
        .frame(minWidth: 180, idealWidth: 240, maxWidth: 360)
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
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
