import SwiftUI
import AppKit

/// First-launch onboarding panel.  Asks the user where to store their notes
/// and adopts that folder as the workspace.  Shown when the app launches
/// with no saved workspace bookmark.
///
/// Sandbox model: the user grants a parent directory (~/Documents or
/// iCloud Drive root or any custom folder) via NSOpenPanel, then we create
/// a "Marktext Notes" subfolder inside (for the recommended options) and
/// persist a security-scoped bookmark for that subfolder.  The parent
/// grant lapses when the panel closes; only the subfolder bookmark
/// survives across launches.
struct OnboardingView: View {
    @Environment(DocumentStore.self) private var store
    @State private var selection: Choice = .documents
    @State private var iCloudState: ICloudState = .checking
    @State private var lastError: String?
    @State private var isProcessing: Bool = false

    enum Choice: Hashable { case documents, iCloud, custom }
    enum ICloudState { case checking, available, unavailable }

    var body: some View {
        VStack(spacing: 0) {
            hero
                .padding(.top, 36)
                .padding(.bottom, 28)

            choices
                .padding(.horizontal, 36)

            if let lastError {
                Text(lastError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.top, 12)
                    .padding(.horizontal, 36)
                    .multilineTextAlignment(.center)
            }

            Spacer()

            Button(action: handleContinue) {
                Text("Continue")
                    .frame(minWidth: 120)
            }
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .disabled(isProcessing || (selection == .iCloud && iCloudState != .available))
            .padding(.bottom, 32)
        }
        .frame(width: 460, height: 520)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { checkICloud() }
    }

    // MARK: - Hero

    private var hero: some View {
        VStack(spacing: 10) {
            if let icon = NSApp.applicationIconImage {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 72, height: 72)
            }
            Text("Welcome to Marktext Next")
                .font(.system(size: 22, weight: .semibold))
            Text("Where would you like to keep your notes?")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Choices

    private var choices: some View {
        VStack(spacing: 8) {
            ChoiceRow(
                icon: "doc.text",
                title: "Documents folder",
                subtitle: "~/Documents/Marktext Notes",
                badge: "Recommended",
                isSelected: selection == .documents,
                isEnabled: true,
                onSelect: { selection = .documents }
            )
            ChoiceRow(
                icon: "icloud",
                title: "iCloud Drive",
                subtitle: iCloudSubtitle,
                badge: nil,
                isSelected: selection == .iCloud,
                isEnabled: iCloudState == .available,
                onSelect: {
                    if iCloudState == .available { selection = .iCloud }
                }
            )
            ChoiceRow(
                icon: "folder.badge.gearshape",
                title: "Choose a custom location",
                subtitle: "Pick any folder on your Mac",
                badge: nil,
                isSelected: selection == .custom,
                isEnabled: true,
                onSelect: { selection = .custom }
            )
        }
    }

    private var iCloudSubtitle: String {
        switch iCloudState {
        case .checking: return "Checking…"
        case .available: return "Synced to your other devices"
        case .unavailable: return "Sign in to iCloud to enable"
        }
    }

    // MARK: - iCloud detection

    private func checkICloud() {
        if FileManager.default.ubiquityIdentityToken != nil {
            iCloudState = .available
            return
        }
        // Token can be momentarily nil during cold-launch even with iCloud
        // signed in.  Re-check after 1.5s before declaring unavailable.
        iCloudState = .checking
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            iCloudState = FileManager.default.ubiquityIdentityToken != nil ? .available : .unavailable
        }
    }

    // MARK: - Continue → folder selection

    private func handleContinue() {
        guard !isProcessing else { return }
        lastError = nil
        isProcessing = true
        defer { isProcessing = false }

        switch selection {
        case .documents:
            requestParentAndCreate(
                initialURL: userHomeURL().appendingPathComponent("Documents"),
                subfolderName: "Marktext Notes",
                message: "Marktext will create a “Marktext Notes” folder inside Documents to store your notes."
            )
        case .iCloud:
            let initial = userHomeURL().appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
            requestParentAndCreate(
                initialURL: initial,
                subfolderName: "Marktext Notes",
                message: "Marktext will create a “Marktext Notes” folder in your iCloud Drive."
            )
        case .custom:
            pickCustomFolder()
        }
    }

    /// Open NSOpenPanel rooted at `initialURL`, expect user to grant the
    /// parent, then create `subfolderName` inside and adopt that.
    private func requestParentAndCreate(initialURL: URL, subfolderName: String, message: String) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Use This Folder"
        panel.message = message
        panel.directoryURL = initialURL

        guard panel.runModal() == .OK, let parent = panel.url else {
            DebugLog.write("[onboard] panel cancelled (parent)")
            return // stay on onboarding
        }
        let target = parent.appendingPathComponent(subfolderName, isDirectory: true)
        do {
            if !FileManager.default.fileExists(atPath: target.path) {
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
            }
            adopt(target)
        } catch {
            lastError = "Couldn't create folder: \(error.localizedDescription)"
            DebugLog.write("[onboard] subfolder mkdir failed: \(error.localizedDescription)")
        }
    }

    private func pickCustomFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Use This Folder"
        panel.message = "Choose any folder where Marktext should keep your notes."
        guard panel.runModal() == .OK, let url = panel.url else {
            DebugLog.write("[onboard] panel cancelled (custom)")
            return
        }
        adopt(url)
    }

    private func adopt(_ url: URL) {
        DebugLog.write("[onboard] adopting workspace: \(url.path)")
        store.adoptFolder(url)
        WorkspaceBookmark.save(url)
        UserDefaults.standard.set(true, forKey: "didShowFirstLaunchOnboarding")
    }

    private func userHomeURL() -> URL {
        // In sandboxed apps, NSHomeDirectory() returns the container path,
        // not the user's real home.  Use NSHomeDirectoryForUser so the
        // NSOpenPanel's directoryURL lands in the visible filesystem.
        if let path = NSHomeDirectoryForUser(NSUserName()) {
            return URL(fileURLWithPath: path)
        }
        return URL(fileURLWithPath: NSHomeDirectory())
    }
}

// MARK: - Choice row

private struct ChoiceRow: View {
    let icon: String
    let title: String
    let subtitle: String
    let badge: String?
    let isSelected: Bool
    let isEnabled: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 18))
                    .frame(width: 26, height: 26)
                    .foregroundStyle(isEnabled ? Color.accentColor : Color.secondary)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(title)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(isEnabled ? Color.primary : Color.secondary)
                        if let badge {
                            Text(badge)
                                .font(.system(size: 10, weight: .medium))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.accentColor.opacity(0.18))
                                .foregroundStyle(Color.accentColor)
                                .clipShape(Capsule())
                        }
                    }
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(Color.accentColor)
                } else {
                    Image(systemName: "circle")
                        .font(.system(size: 16))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 12)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? Color.accentColor.opacity(0.10) : Color.gray.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(
                        isSelected ? Color.accentColor.opacity(0.5) : Color.gray.opacity(0.15),
                        lineWidth: isSelected ? 1.5 : 1
                    )
            )
            .opacity(isEnabled ? 1.0 : 0.55)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
    }
}
