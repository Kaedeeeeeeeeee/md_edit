import SwiftUI

enum AppearancePreference: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }

    var label: String {
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

struct SettingsView: View {
    @AppStorage("autoSaveEnabled") private var autoSaveEnabled = true
    @AppStorage("autoSaveDelaySeconds") private var autoSaveDelaySeconds = 2.0
    @AppStorage("appearancePreference") private var appearance: AppearancePreference = .system
    @State private var isDefaultHandler = DefaultMarkdownHandler.isDefault()

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
                            ? "Marktext Next is the default app for .md files."
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
                    Text("Set Marktext Next as the system-wide default for double-clicking .md files. macOS may ask you to confirm.")
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
            }
            .formStyle(.grouped)
            .padding()
            .tabItem { Label("Appearance", systemImage: "paintpalette") }
        }
        .frame(minWidth: 460, minHeight: 280)
        .onChange(of: appearance) { _, newValue in
            applyAppearance(newValue)
        }
        .onAppear {
            applyAppearance(appearance)
            isDefaultHandler = DefaultMarkdownHandler.isDefault()
        }
    }

    private func applyAppearance(_ pref: AppearancePreference) {
        NSApp.appearance = pref.nsAppearance
    }
}
