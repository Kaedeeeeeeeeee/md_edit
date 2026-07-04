import SwiftUI
import AppKit

/// First-launch onboarding panel.  Two-button layout:
///   - **Not now** (default, ⏎): adopt the in-container "Notation Notes"
///     folder, no sandbox grant needed, zero file-picker friction.
///   - **Set up iCloud sync**: only enabled if the user is signed into
///     iCloud.  Opens NSOpenPanel pre-filled to iCloud Drive so the user
///     can grant access; we then create "Notation Notes" inside.
///
/// Either path ends at the editor with a workspace already adopted.
/// Migrating from container to iCloud / Documents / custom location is
/// available later via Settings.
struct OnboardingView: View {
    @Environment(DocumentStore.self) private var store
    @State private var iCloudState: ICloudState = .checking
    @State private var lastError: String?
    @State private var isProcessing: Bool = false

    enum ICloudState { case checking, available, unavailable }

    var body: some View {
        VStack(spacing: 0) {
            hero
                .padding(.top, 40)
                .padding(.bottom, 24)

            messaging
                .padding(.horizontal, 36)
                .padding(.bottom, 12)

            if let lastError {
                Text(lastError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.top, 4)
                    .padding(.horizontal, 36)
                    .multilineTextAlignment(.center)
            }

            Spacer()

            buttons
                .padding(.bottom, 32)
        }
        .frame(width: 460, height: 480)
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
            Text("Welcome to Notation")
                .font(.system(size: 22, weight: .semibold))
        }
    }

    // MARK: - Body text

    private var messaging: some View {
        VStack(spacing: 8) {
            Text("Your notes will be saved automatically.")
                .font(.system(size: 14))
                .foregroundStyle(.primary)
            Text("Want to sync them across your devices via iCloud?")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Buttons

    private var buttons: some View {
        VStack(spacing: 10) {
            // Primary = zero-friction default.  Pressing Return triggers
            // this; clicking it skips any sandbox panel.  Visual prominence
            // matches the default behaviour.
            Button(action: useContainerVault) {
                Text("Get started")
                    .frame(width: 260)
                    .padding(.vertical, 2)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(isProcessing)

            // Secondary = explicit iCloud setup with one NSOpenPanel grant.
            Button(action: setupICloud) {
                HStack(spacing: 8) {
                    Image(systemName: "icloud")
                    Text(iCloudButtonLabel)
                }
                .frame(width: 260)
                .padding(.vertical, 2)
            }
            .controlSize(.large)
            .buttonStyle(.bordered)
            .disabled(isProcessing || iCloudState != .available)

            Text("You can move notes to iCloud or any folder later in Settings.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .padding(.top, 6)
        }
    }

    private var iCloudButtonLabel: String {
        switch iCloudState {
        case .checking: return "Checking iCloud…"
        case .available: return "Set up iCloud sync…"
        case .unavailable: return "iCloud not available"
        }
    }

    // MARK: - iCloud detection

    private func checkICloud() {
        if FileManager.default.ubiquityIdentityToken != nil {
            iCloudState = .available
            return
        }
        iCloudState = .checking
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            iCloudState = FileManager.default.ubiquityIdentityToken != nil ? .available : .unavailable
        }
    }

    // MARK: - Container vault (zero-friction default)

    private func useContainerVault() {
        guard !isProcessing else { return }
        lastError = nil
        isProcessing = true
        defer { isProcessing = false }

        // Sandbox `~/Library/Containers/com.notation.app/Data/Documents/`.
        // The app has full read-write here without any user grant.
        guard let containerDocuments = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask).first else {
            lastError = "Couldn't locate the app's Documents directory."
            DebugLog.write("[onboard] container Documents dir not found")
            return
        }
        let target = containerDocuments.appendingPathComponent("Notation Notes", isDirectory: true)
        do {
            if !FileManager.default.fileExists(atPath: target.path) {
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            }
            adopt(target)
        } catch {
            lastError = "Couldn't create vault folder: \(error.localizedDescription)"
            DebugLog.write("[onboard] container vault mkdir failed: \(error.localizedDescription)")
        }
    }

    // MARK: - iCloud Drive vault (one NSOpenPanel)

    private func setupICloud() {
        guard !isProcessing else { return }
        guard iCloudState == .available else { return }
        lastError = nil
        isProcessing = true
        defer { isProcessing = false }

        let initial = userHomeURL()
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")

        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Use This Folder"
        panel.message = "Notation will create a “Notation Notes” folder in your iCloud Drive to sync across your devices."
        panel.directoryURL = initial

        guard panel.runModal() == .OK, let parent = panel.url else {
            DebugLog.write("[onboard] iCloud panel cancelled")
            return
        }
        let target = parent.appendingPathComponent("Notation Notes", isDirectory: true)
        do {
            if !FileManager.default.fileExists(atPath: target.path) {
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
            }
            adopt(target)
        } catch {
            lastError = "Couldn't create folder: \(error.localizedDescription)"
            DebugLog.write("[onboard] iCloud mkdir failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Adopt

    private func adopt(_ url: URL) {
        DebugLog.write("[onboard] adopting workspace: \(url.path)")
        store.adoptWorkspaceFolder(url)
        UserDefaults.standard.set(true, forKey: "didShowFirstLaunchOnboarding")
    }

    private func userHomeURL() -> URL {
        if let path = NSHomeDirectoryForUser(NSUserName()) {
            return URL(fileURLWithPath: path)
        }
        return URL(fileURLWithPath: NSHomeDirectory())
    }
}
