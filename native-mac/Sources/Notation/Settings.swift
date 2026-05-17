import SwiftUI

enum AppearancePreference: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }

    var label: LocalizedStringKey {
        switch self {
        case .system: return "Match System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

/// User-controllable language override. `.system` means "fall back to the
/// system's preferred language list" — when chosen, we delete our override of
/// `AppleLanguages` from UserDefaults so macOS resolves it normally on the
/// next launch.
enum LanguagePreference: String, CaseIterable, Identifiable {
    case system, en, zhHans
    var id: String { rawValue }

    /// Label shown in the picker.  "简体中文" stays in Chinese in both
    /// locales (standard convention: native name); the key isn't present
    /// in any .strings table so SwiftUI falls back to the literal.
    var label: LocalizedStringKey {
        switch self {
        case .system: return "Match System"
        case .en:     return "English"
        case .zhHans: return "简体中文"
        }
    }

    /// Code written into the `AppleLanguages` array.  `nil` means "remove
    /// the override entirely".
    var languageCode: String? {
        switch self {
        case .system: return nil
        case .en:     return "en"
        case .zhHans: return "zh-Hans"
        }
    }
}

struct SettingsView: View {
    @AppStorage("autoSaveEnabled") private var autoSaveEnabled = true
    @AppStorage("autoSaveDelaySeconds") private var autoSaveDelaySeconds = 2.0
    @AppStorage("appearancePreference") private var appearance: AppearancePreference = .system
    @AppStorage("languagePreference") private var language: LanguagePreference = .system
    @AppStorage("aiProvider") private var aiProviderRaw: String = AIProvider.anthropic.rawValue
    @AppStorage("aiDisclosureAcked") private var aiDisclosureAcked = false
    @AppStorage("aiAnthropicModel") private var aiAnthropicModel: String = ""
    @AppStorage("aiOpenAIModel") private var aiOpenAIModel: String = ""
    @AppStorage("aiOpenAIBaseURL") private var aiOpenAIBaseURL: String = ""
    @Environment(EntitlementState.self) private var entitlement
    @State private var isDefaultHandler = DefaultMarkdownHandler.isDefault()
    /// Tracks whether the user has actually toggled the picker this session,
    /// so the initial `.onAppear`-driven read doesn't trip the restart prompt.
    @State private var initialLanguage: LanguagePreference?
    @State private var aiKeyDraft: String = ""
    @State private var aiKeyStatus: String = ""
    @State private var aiPendingProviderAfterDisclosure: AIProvider?

    private var aiProvider: AIProvider {
        AIProvider(rawValue: aiProviderRaw) ?? .anthropic
    }

    var body: some View {
        TabView {
            Form {
                Section {
                    Toggle("Save automatically while editing", isOn: $autoSaveEnabled)
                    if autoSaveEnabled {
                        HStack {
                            Text("Save after")
                            Slider(
                                value: $autoSaveDelaySeconds,
                                in: 0.5...10,
                                step: 0.5
                            )
                            .frame(maxWidth: 220)
                            Text(String(format: "%.1f s", autoSaveDelaySeconds))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Auto-Save")
                } footer: {
                    Text("Auto-save persists every change. Untitled documents are saved into your workspace with a timestamped filename — you can rename them later.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Recent Files") {
                    Button("Clear Recent Files") {
                        RecentFiles.shared.clear()
                    }
                }

                Section {
                    HStack {
                        Text(isDefaultHandler
                            ? "Notation is the default app for .md files."
                            : "Another app is currently the default for .md files.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Make Default") {
                            DefaultMarkdownHandler.claimAsDefault()
                            // Recheck after the system has had a moment to
                            // apply / prompt — the API is async.
                            Task { @MainActor in
                                try? await Task.sleep(nanoseconds: 300_000_000)
                                isDefaultHandler = DefaultMarkdownHandler.isDefault()
                            }
                        }
                        .disabled(isDefaultHandler)
                    }
                } header: {
                    Text("File Associations")
                } footer: {
                    Text("Set Notation as the system-wide default for double-clicking .md files. macOS may ask you to confirm.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .padding()
            .tabItem { Label("General", systemImage: "gearshape") }

            Form {
                Section("Appearance") {
                    Picker("Theme", selection: $appearance) {
                        ForEach(AppearancePreference.allCases) { choice in
                            Text(choice.label).tag(choice)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section("Language") {
                    Picker("Language", selection: $language) {
                        ForEach(LanguagePreference.allCases) { choice in
                            Text(choice.label).tag(choice)
                        }
                    }
                    .pickerStyle(.segmented)
                }
            }
            .formStyle(.grouped)
            .padding()
            .tabItem { Label("Appearance", systemImage: "paintpalette") }

            Form {
                // Pro gating callout: appears above all other AI controls so
                // users immediately know AI features require an upgrade.
                // API Key entry is intentionally left enabled so preparation
                // is possible without Pro — the gating happens at the call
                // sites (EditorWebView, AgentChatController), not here.
                if !entitlement.isPro {
                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Image(systemName: "lock.fill")
                                    .foregroundStyle(Color.accentColor)
                                Text("AI features require Notation Pro upgrade")
                                    .font(.headline)
                                Spacer()
                            }
                            Text("Unlock Ask AI, Research, and Image Generation. App is free; AI features available via monthly, yearly, or lifetime purchase.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            HStack {
                                Spacer()
                                Button("Upgrade…") {
                                    NotificationCenter.default.post(name: .proPaywallRequested, object: nil)
                                }
                                .buttonStyle(.borderedProminent)
                            }
                        }
                        .padding(8)
                    }
                } else {
                    // Already Pro — show a small status row instead.
                    Section {
                        HStack {
                            Image(systemName: "checkmark.seal.fill")
                                .foregroundStyle(.green)
                            Text("Upgraded to Notation Pro")
                            if let tier = entitlement.activeTier {
                                Text("· \(tier.displayName)")
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                    }
                }

                if !aiDisclosureAcked {
                    // Up-front data-handling disclosure shown the first time
                    // the AI tab is opened. Replaces the older NSAlert that
                    // fired only at key-save time — App Store reviewers want
                    // the user informed before they invest effort.
                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Sending text to AI providers")
                                .font(.headline)
                            Text("When you use Ask AI, Research, or Image Generation, the selected text and your instruction are sent over HTTPS to the AI provider you choose (Anthropic or OpenAI / compatible). Your API key is stored in macOS Keychain on this device only — it is never sent to us. The provider you choose handles your data per their own privacy policy.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            HStack {
                                Spacer()
                                Button("Got it") { aiDisclosureAcked = true }
                                    .buttonStyle(.borderedProminent)
                            }
                        }
                        .padding(8)
                    }
                }

                Section {
                    Picker("Provider", selection: Binding(
                        get: { aiProvider },
                        set: { newValue in
                            aiProviderRaw = newValue.rawValue
                            reloadAIKeyDraft()
                        }
                    )) {
                        ForEach(AIProvider.allCases) { p in
                            Text(p.displayName).tag(p)
                        }
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("AI Provider")
                } footer: {
                    Text("Your selected text and prompts will be sent to the chosen provider's servers when you use Ask AI.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    if aiProvider == .openai {
                        TextField(
                            "Base URL",
                            text: $aiOpenAIBaseURL,
                            prompt: Text(AIProvider.openai.defaultBaseURL)
                        )
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                        .textContentType(.URL)
                    }
                    TextField(
                        "Model",
                        text: aiProvider == .anthropic ? $aiAnthropicModel : $aiOpenAIModel,
                        prompt: Text(aiProvider.defaultModel)
                    )
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                } header: {
                    Text("Model")
                } footer: {
                    if aiProvider == .openai {
                        Text("Leave fields blank to use the OpenAI defaults. To use DeepSeek, set Base URL to https://api.deepseek.com/v1 and Model to e.g. deepseek-chat. Works with any OpenAI-compatible API (Groq, Together, Fireworks, OpenRouter, local Ollama).")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Leave blank to use the default (\(AIProvider.anthropic.defaultModel)).")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    SecureField("API key", text: $aiKeyDraft)
                        .textFieldStyle(.roundedBorder)
                    HStack {
                        Button("Save Key") { saveAIKey() }
                            .disabled(aiKeyDraft.isEmpty)
                        Button("Clear") { clearAIKey() }
                            .disabled(!hasStoredAIKey())
                        Spacer()
                        if !aiKeyStatus.isEmpty {
                            Text(aiKeyStatus)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("\(aiProvider.displayName) API Key")
                } footer: {
                    Text("Stored in macOS Keychain. Never written to disk in plain text and never sent to anywhere except the provider you chose.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .padding()
            .tabItem { Label("AI", systemImage: "sparkles") }
        }
        .frame(minWidth: 460, minHeight: 280)
        .onChange(of: appearance) { _, newValue in
            applyAppearance(newValue)
        }
        .onChange(of: language) { _, newValue in
            handleLanguageChange(to: newValue)
        }
        .onAppear {
            applyAppearance(appearance)
            isDefaultHandler = DefaultMarkdownHandler.isDefault()
            if initialLanguage == nil { initialLanguage = language }
            reloadAIKeyDraft()
        }
    }

    private func reloadAIKeyDraft() {
        aiKeyDraft = ""
        if let masked = KeychainStore.maskedDisplay(account: aiProvider.keychainAccount) {
            // `String(format: String(localized:))` rather than direct
            // interpolation because Swift variable-assignment string literals
            // skip SwiftUI's implicit LocalizedStringKey lookup.
            aiKeyStatus = String(format: String(localized: "Saved: %@"), masked)
        } else {
            aiKeyStatus = ""
        }
    }

    private func hasStoredAIKey() -> Bool {
        KeychainStore.load(account: aiProvider.keychainAccount) != nil
    }

    private func saveAIKey() {
        let trimmed = aiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if KeychainStore.save(account: aiProvider.keychainAccount, secret: trimmed) {
            aiKeyDraft = ""
            reloadAIKeyDraft()
        } else {
            aiKeyStatus = String(localized: "Failed to save (see debug log)")
        }
    }

    private func clearAIKey() {
        KeychainStore.delete(account: aiProvider.keychainAccount)
        aiKeyDraft = ""
        reloadAIKeyDraft()
    }

    private func applyAppearance(_ pref: AppearancePreference) {
        NSApp.appearance = pref.nsAppearance
    }

    /// Writes / clears the `AppleLanguages` override and prompts the user to
    /// restart.  We don't try to live-switch the UI because the macOS menu
    /// bar (NSMenu) and NSAlert system buttons don't honour
    /// `.environment(\.locale, …)` — only a relaunch keeps the whole app
    /// in one language.
    private func handleLanguageChange(to newValue: LanguagePreference) {
        // Avoid prompting if the user just opened Settings without touching
        // the picker (the `.onChange` initial-render guard).
        guard let initial = initialLanguage, initial != newValue else { return }

        // Persist the override into UserDefaults.AppleLanguages so the next
        // launch picks it up before any view appears.
        let defaults = UserDefaults.standard
        if let code = newValue.languageCode {
            defaults.set([code], forKey: "AppleLanguages")
        } else {
            defaults.removeObject(forKey: "AppleLanguages")
        }
        defaults.synchronize()

        let alert = NSAlert()
        alert.messageText = String(localized: "Restart Notation to apply language change")
        alert.informativeText = String(localized: "The new language will take effect after the app restarts.")
        alert.alertStyle = .informational
        alert.addButton(withTitle: String(localized: "Restart Now"))
        alert.addButton(withTitle: String(localized: "Later"))

        if alert.runModal() == .alertFirstButtonReturn {
            restartApp()
        } else {
            // User chose "Later" — bump the baseline so a second toggle in
            // the same Settings session prompts again from the new state.
            initialLanguage = newValue
        }
    }

    private func restartApp() {
        let url = Bundle.main.bundleURL
        let task = Process()
        task.launchPath = "/usr/bin/open"
        task.arguments = ["-n", url.path]
        // `try?` because launching a new copy can race with the terminate
        // below; either way we terminate ourselves so the user only has one
        // running copy when the new process finishes activating.
        try? task.run()
        NSApp.terminate(nil)
    }
}
