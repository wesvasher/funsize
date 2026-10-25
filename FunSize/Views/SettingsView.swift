import SwiftUI

/// Pages in the Settings window's sidebar.
enum SettingsPage: String, CaseIterable, Identifiable {
    case general
    case exportPresets

    /// Remembers the last page; other windows set it to open Settings on a page.
    static let storageKey = "settingsPage"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .exportPresets: "Export Presets"
        }
    }

    var systemImage: String {
        switch self {
        case .general: "gearshape"
        case .exportPresets: "square.and.arrow.up.on.square"
        }
    }

    var tint: Color {
        switch self {
        case .general: .gray
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
                case .exportPresets: ExportPresetsSettingsView()
                }
            }
            .navigationTitle(page.title)
        }
        .frame(width: 820, height: 620)
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
