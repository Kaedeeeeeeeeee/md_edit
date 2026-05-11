import SwiftUI
import AppKit

/// Launch-time workspace picker styled after JetBrains / VS Code launchers:
/// compact header, search, dense recents list with relative timestamps,
/// and a quiet bottom bar.  Selecting a row adopts the folder into the
/// shared DocumentStore, opens the main editor window, and dismisses
/// itself.
struct WorkspacePicker: View {
    @Environment(DocumentStore.self) private var store
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @AppStorage("skipPickerOnLaunch") private var skipOnLaunch = false

    @State private var entries: [WorkspaceEntry] = []
    @State private var query = ""
    @State private var selectedID: String?
    @State private var didAutoSkip = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            searchBar
            Divider().opacity(0.4)
            recentsList
            Divider()
            bottomBar
        }
        .frame(width: 720, height: 500)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { setup() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            if let icon = NSApp.applicationIconImage {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 32, height: 32)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text("Marktext Next")
                    .font(.system(size: 16, weight: .semibold))
                Text("Markdown editor")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text("v\(appVersion)")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .monospacedDigit()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    // MARK: - Search

    private var searchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.tertiary)
                .font(.system(size: 12, weight: .medium))
            TextField("Search workspaces", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 0.5)
        )
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    // MARK: - Recents

    @ViewBuilder
    private var recentsList: some View {
        let filtered = filteredEntries
        if filtered.isEmpty {
            emptyState
        } else {
            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(filtered) { entry in
                        WorkspaceRow(
                            entry: entry,
                            isSelected: selectedID == entry.id,
                            onTap: { open(entry) },
                            onHover: { hovering in
                                if hovering { selectedID = entry.id }
                            }
                        )
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: query.isEmpty ? "tray" : "magnifyingglass")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            if query.isEmpty {
                Text("No recent workspaces yet")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                Text("Open a folder below to get started.")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            } else {
                Text("No matches for \"\(query)\"")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Bottom action bar

    private var bottomBar: some View {
        HStack(spacing: 10) {
            Button {
                pickNewFolder()
            } label: {
                Label("Open Folder…", systemImage: "folder.badge.plus")
                    .font(.system(size: 12))
            }
            .controlSize(.regular)
            .keyboardShortcut("o", modifiers: .command)

            if !entries.isEmpty {
                Button("Clear Recents") {
                    WorkspaceBookmark.clearRecent()
                    reload()
                }
                .controlSize(.regular)
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .font(.system(size: 12))
            }

            Spacer()

            Toggle(isOn: $skipOnLaunch) {
                Text("Open last workspace on launch")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .toggleStyle(.checkbox)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    // MARK: - Logic

    private var filteredEntries: [WorkspaceEntry] {
        guard !query.isEmpty else { return entries }
        let q = query.lowercased()
        return entries.filter {
            $0.name.lowercased().contains(q) || $0.path.lowercased().contains(q)
        }
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1"
    }

    private func setup() {
        reload()
        selectedID = entries.first?.id

        // Auto-skip: if user opted in AND we have a workspace to open,
        // restore the most recent one and slide straight into the editor.
        if !didAutoSkip, skipOnLaunch, let first = entries.first {
            didAutoSkip = true
            open(first)
        }
    }

    private func reload() {
        let raw = WorkspaceBookmark.recentWorkspaces()
        entries = raw.map { item in
            WorkspaceEntry(
                url: item.url,
                name: item.displayName,
                lastAccessed: WorkspaceBookmark.lastAccessed(for: item.url)
            )
        }
    }

    private func open(_ entry: WorkspaceEntry) {
        store.adoptRecentWorkspace(entry.url)
        transitionToMain()
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

    private func transitionToMain() {
        openWindow(id: "main")
        dismissWindow(id: "picker")
    }
}

// MARK: - Row model

private struct WorkspaceEntry: Identifiable {
    let url: URL
    let name: String
    let lastAccessed: Date?

    var id: String { url.absoluteString }
    var path: String { url.path }
}

// MARK: - Row view

private struct WorkspaceRow: View {
    let entry: WorkspaceEntry
    let isSelected: Bool
    let onTap: () -> Void
    let onHover: (Bool) -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                Image(systemName: "folder.fill")
                    .foregroundStyle(Color.accentColor)
                    .font(.system(size: 18))
                    .frame(width: 24, alignment: .center)

                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.name)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(shortPath)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 12)

                if let date = entry.lastAccessed {
                    Text(WorkspaceRow.dateFormatter.localizedString(for: date, relativeTo: .now))
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(rowBackground)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { value in
            hovering = value
            onHover(value)
        }
    }

    private var rowBackground: Color {
        if isSelected { return Color.accentColor.opacity(hovering ? 0.18 : 0.14) }
        if hovering { return Color(nsColor: .quaternaryLabelColor).opacity(0.4) }
        return .clear
    }

    private var shortPath: String {
        let path = entry.path
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        if components.count >= 2, components[0] == "Users" {
            return "~/\(components.dropFirst(2).joined(separator: "/"))"
        }
        return path
    }

    private static let dateFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()
}
