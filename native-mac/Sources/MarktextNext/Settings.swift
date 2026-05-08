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
    @AppStorage("autoSaveEnabled") private var autoSaveEnabled = false
    @AppStorage("autoSaveDelaySeconds") private var autoSaveDelaySeconds = 2.0
    @AppStorage("appearancePreference") private var appearance: AppearancePreference = .system

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
                    Text("Auto-save only writes when the document already has a file path. New documents must be saved manually first.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Recent Files") {
                    Button("Clear Recent Files") {
                        RecentFiles.shared.clear()
                    }
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
        }
    }

    private func applyAppearance(_ pref: AppearancePreference) {
        NSApp.appearance = pref.nsAppearance
    }
}
