import SwiftUI

/// Pages in the Settings window's sidebar.
enum SettingsPage: String, CaseIterable, Identifiable {
    case general
    case appearance
    case color
    case exportPresets

    /// Remembers the last page; other windows set it to open Settings on a page.
    static let storageKey = "settingsPage"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .appearance: "Appearance"
        case .color: "Color"
        case .exportPresets: "Export Presets"
        }
    }

    var systemImage: String {
        switch self {
        case .general: "gearshape"
        case .appearance: "circle.lefthalf.filled"
        case .color: "paintpalette"
        case .exportPresets: "square.and.arrow.up.on.square"
        }
    }

    var tint: Color {
        switch self {
        case .general: .gray
        case .appearance: .indigo
        case .color: .orange
        case .exportPresets: .blue
        }
    }
}

/// Settings: a sidebar of pages, with the chosen page on the right (like System Settings).
struct SettingsView: View {
    @AppStorage(SettingsPage.storageKey) private var page: SettingsPage = .general

    var body: some View {
        NavigationSplitView {
            List(SettingsPage.allCases, selection: Binding(get: { page }, set: { if let new = $0 { page = new } })) { page in
                Label {
                    Text(page.title)
                } icon: {
                    Image(systemName: page.systemImage)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 20, height: 20)
                        .background(page.tint.gradient, in: RoundedRectangle(cornerRadius: 5))
                }
                .tag(page)
            }
            .frame(minWidth: 200)
            .navigationSplitViewColumnWidth(min: 200, ideal: 210, max: 260)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            Group {
                switch page {
                case .general: GeneralSettingsView()
                case .appearance: AppearanceSettingsView()
                case .color: ColorSettingsView()
                case .exportPresets: ExportPresetsSettingsView()
                }
            }
            .navigationTitle(page.title)
        }
        .frame(width: 820, height: 620)
    }
}

/// SwiftCut's light/dark setting.
enum AppAppearance: String, CaseIterable, Identifiable {
    case auto, light, dark

    var id: String { rawValue }
    static let storageKey = "appAppearance"

    /// Applies the setting to every window in the app.
    func apply() {
        switch self {
        case .auto: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    static var saved: AppAppearance {
        AppAppearance(rawValue: UserDefaults.standard.string(forKey: storageKey) ?? "") ?? .auto
    }
}

/// Settings › Appearance: light, dark, or matching the Mac (same tiles as CardStock).
struct AppearanceSettingsView: View {
    @AppStorage(AppAppearance.storageKey) private var appearance = AppAppearance.auto

    var body: some View {
        Form {
            Section("Appearance") {
                ChoiceCards(selection: $appearance, options: [
                    .init(value: .auto, title: "Auto", systemImage: "circle.lefthalf.filled", help: "Match your Mac's setting"),
                    .init(value: .light, title: "Light", systemImage: "sun.max.fill", help: "Always use light windows"),
                    .init(value: .dark, title: "Dark", systemImage: "moon.fill", help: "Always use dark windows"),
                ])
                Text("Auto follows your Mac's setting in System Settings › Appearance.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onChange(of: appearance) { _, new in new.apply() }
    }
}

struct GeneralSettingsView: View {
    @Environment(ExportManager.self) private var exporter

    var body: some View {
        @Bindable var exporter = exporter

        Form {
            Section("Exports") {
                Toggle("Show in Finder when an export finishes", isOn: $exporter.revealWhenFinished)
            }
        }
        .formStyle(.grouped)
    }
}
