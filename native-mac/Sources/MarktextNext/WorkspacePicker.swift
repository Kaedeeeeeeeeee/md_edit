import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Launch-time workspace picker styled after Xcode's "Welcome to Xcode"
/// window: hidden title bar, two columns (centred app hero on the left,
/// recents list on the right), full-bleed selection rows, and a
/// "show on launch" checkbox at the bottom.
struct WorkspacePicker: View {
    @Environment(DocumentStore.self) private var store
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @AppStorage("showPickerOnLaunch") private var showOnLaunch = true

    @State private var entries: [WorkspaceEntry] = []
    @State private var didAutoSkip = false

    var body: some View {
        HStack(spacing: 0) {
            leftPane
                .frame(width: 300)
            rightPane
                .frame(maxWidth: .infinity)
        }
        .frame(width: 640, height: 420)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { setup() }
    }

    // MARK: - Left pane

    private var leftPane: some View {
        VStack(spacing: 0) {
            Spacer()

            // Hero icon
            if let icon = NSApp.applicationIconImage {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 100, height: 100)
                    .padding(.bottom, 12)
            }

            // Title + version
            VStack(spacing: 2) {
                Text("Marktext Next")
                    .font(.system(size: 23, weight: .regular))
                Text("Version \(appVersion)")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .padding(.bottom, 22)

            // Action pills
            VStack(spacing: 6) {
                PillAction(
                    systemImage: "plus.circle",
                    title: "New File…",
                    action: newFile
                )
                PillAction(
                    systemImage: "folder",
                    title: "Open Folder…",
                    action: pickNewFolder,
                    shortcut: ("o", .command)
                )
                PillAction(
                    systemImage: "doc",
                    title: "Open Existing File…",
                    action: openExistingFile
                )
            }
            .frame(maxWidth: 230)

            Spacer()

            // Show-on-launch toggle (Xcode's bottom-left checkbox)
            Toggle(isOn: $showOnLaunch) {
                Text("Show on launch")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .toggleStyle(.checkbox)
            .controlSize(.small)
            .padding(.bottom, 12)
        }
        .padding(.horizontal, 16)
    }

    // MARK: - Right pane

    @ViewBuilder
    private var rightPane: some View {
        if entries.isEmpty {
            VStack(spacing: 6) {
                Spacer()
                Image(systemName: "tray")
                    .font(.system(size: 22))
                    .foregroundStyle(.tertiary)
                Text("No recent workspaces")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Text("Open a folder to get started.")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(entries) { entry in
                        RecentRow(entry: entry) { open(entry) }
                    }
                }
                .padding(.vertical, 10)
                .padding(.trailing, 10)
            }
        }
    }

    // MARK: - Logic

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1"
    }

    private func setup() {
        reload()
        if !didAutoSkip, !showOnLaunch, let first = entries.first {
            didAutoSkip = true
            open(first)
        }
    }

    private func reload() {
        let raw = WorkspaceBookmark.recentWorkspaces()
        entries = raw.map {
            WorkspaceEntry(
                url: $0.url,
                name: $0.displayName,
                lastAccessed: WorkspaceBookmark.lastAccessed(for: $0.url)
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

    private func newFile() {
        store.newDocument()
        transitionToMain()
    }

    private func openExistingFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.plainText]
        if let md = UTType(filenameExtension: "md") {
            panel.allowedContentTypes.append(md)
        }
        panel.title = "Open Markdown File"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        store.loadFile(url)
        transitionToMain()
    }

    private func transitionToMain() {
        openWindow(id: "main")
        dismissWindow(id: "picker")
    }
}

// MARK: - Models

private struct WorkspaceEntry: Identifiable {
    let url: URL
    let name: String
    let lastAccessed: Date?
    var id: String { url.absoluteString }
    var path: String { url.path }
}

// MARK: - Pill button

private struct PillAction: View {
    let systemImage: String
    let title: String
    let action: () -> Void
    var shortcut: (Character, EventModifiers)? = nil
    @State private var hovering = false

    var body: some View {
        let button = Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: systemImage)
                    .font(.system(size: 12, weight: .regular))
                    .frame(width: 16, alignment: .center)
                Text(title)
                    .font(.system(size: 12, weight: .regular))
                Spacer(minLength: 0)
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(
                Capsule()
                    .fill(
                        hovering
                            ? Color(nsColor: .quaternaryLabelColor).opacity(0.7)
                            : Color(nsColor: .quaternaryLabelColor).opacity(0.4)
                    )
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }

        if let (key, mods) = shortcut {
            button.keyboardShortcut(KeyEquivalent(key), modifiers: mods)
        } else {
            button
        }
    }
}

// MARK: - Recent row (Xcode-style)

private struct RecentRow: View {
    let entry: WorkspaceEntry
    let onTap: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 9) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(
                            LinearGradient(
                                colors: [Color.accentColor.opacity(0.85), Color.accentColor],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .frame(width: 30, height: 30)
                    Image(systemName: "folder.fill")
                        .font(.system(size: 14, weight: .regular))
                        .foregroundStyle(.white)
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.name)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(shortPath)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 8)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(hovering
                        ? Color(nsColor: .quaternaryLabelColor).opacity(0.9)
                        : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }

    private var shortPath: String {
        let path = entry.path
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        if parts.count >= 2, parts[0] == "Users" {
            return "~/\(parts.dropFirst(2).joined(separator: "/"))"
        }
        return path
    }
}
