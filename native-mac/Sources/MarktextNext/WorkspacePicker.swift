import SwiftUI
import AppKit

/// Launch-time workspace picker, à la VS Code / Cursor / Xcode.  Lists the
/// recently-opened workspace folders so the user can jump straight back in
/// without going through Finder; an "Open Folder…" button covers the
/// first-time-or-new-workspace case.  Selecting an item adopts the folder
/// into the shared DocumentStore, opens the main editor window, and
/// dismisses the picker.
struct WorkspacePicker: View {
    @Environment(DocumentStore.self) private var store
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var recents: [(url: URL, displayName: String)] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            header
            openButton
            recentsSection
            Spacer(minLength: 0)
        }
        .padding(28)
        .frame(width: 520, height: 540)
        .onAppear { reloadRecents() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            if let icon = NSApp.applicationIconImage {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 56, height: 56)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Marktext Next")
                    .font(.title)
                    .fontWeight(.semibold)
                Text("Pick a workspace folder to begin.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    // MARK: - Open Folder button

    private var openButton: some View {
        Button(action: pickNewFolder) {
            HStack(spacing: 10) {
                Image(systemName: "folder.badge.plus")
                    .font(.title3)
                Text("Open Folder…")
                    .font(.body)
                    .fontWeight(.medium)
                Spacer()
                Text("⌘O")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .keyboardShortcut("o", modifiers: .command)
    }

    // MARK: - Recents

    @ViewBuilder
    private var recentsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Recent Workspaces")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                if !recents.isEmpty {
                    Button("Clear") {
                        WorkspaceBookmark.clearRecent()
                        reloadRecents()
                    }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }

            if recents.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(recents, id: \.url.absoluteString) { item in
                            RecentRow(item: item) { openRecent(item.url) }
                        }
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            Text("No recent workspaces.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("Pick a folder above to get started.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 32)
    }

    // MARK: - Actions

    private func reloadRecents() {
        recents = WorkspaceBookmark.recentWorkspaces()
    }

    private func pickNewFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.title = "Choose a Workspace Folder"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        store.adoptFolder(url)
        WorkspaceBookmark.save(url)
        transitionToMain()
    }

    private func openRecent(_ url: URL) {
        store.adoptRecentWorkspace(url)
        transitionToMain()
    }

    private func transitionToMain() {
        openWindow(id: "main")
        dismissWindow(id: "picker")
    }
}

// MARK: - Row

private struct RecentRow: View {
    let item: (url: URL, displayName: String)
    let onTap: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                Image(systemName: "folder.fill")
                    .foregroundStyle(Color.accentColor)
                    .font(.title3)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.displayName)
                        .font(.body)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(shortenedPath)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                if hovering {
                    Image(systemName: "chevron.right")
                        .foregroundStyle(.tertiary)
                        .font(.footnote)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(hovering ? Color.accentColor.opacity(0.12) : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }

    /// Trim the leading `/Users/<name>/` so the path doesn't dominate the row.
    private var shortenedPath: String {
        let path = item.url.path
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        if components.count >= 2, components[0] == "Users" {
            let rest = components.dropFirst(2).joined(separator: "/")
            return "~/\(rest)"
        }
        return path
    }
}
