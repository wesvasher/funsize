import SwiftUI

@main
struct SwiftCutApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @State private var exporter = ExportManager()

    var body: some Scene {
        DocumentGroup(newDocument: ProjectDocument()) { file in
            ProjectWindow(document: file.$document, fileURL: file.fileURL)
                .environment(exporter)
        }
        .defaultSize(width: 1200, height: 760)
        .commands {
            PlaybackCommands()
            ProjectCommands()
            HelpCommands()
        }

        Window("Welcome to SwiftCut", id: WelcomeWindow.id) {
            WelcomeView()
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .windowBackgroundDragBehavior(.enabled)
        .restorationBehavior(.disabled)
        .defaultLaunchBehavior(.presented)
        .defaultPosition(.center)
        .keyboardShortcut("1", modifiers: [.command, .shift])

        Settings {
            SettingsView()
                .environment(exporter)
        }
    }
}

/// File menu items for projects.
struct ProjectCommands: Commands {
    @FocusedValue(ProjectStore.self) private var store

    var body: some Commands {
        CommandGroup(after: .sidebar) {
            Button("Go to Timeline") { store?.selection = [.timeline] }
                .keyboardShortcut("1", modifiers: .command)
                .disabled(store == nil || store?.isTimelineSelected == true)
            Button(store?.sidebarsHidden == true ? "Show Sidebars" : "Hide Sidebars") {
                withAnimation { store?.sidebarsHidden.toggle() }
            }
            .keyboardShortcut(".", modifiers: .command)
            .disabled(store == nil)
            Button("Play Full Screen") { store?.playFullScreen() }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(store?.fullScreenSource == nil)
            Divider()
        }
        CommandGroup(replacing: .importExport) {
            Button("Import Videos…") { store?.isImporting = true }
                .keyboardShortcut("i", modifiers: [.command, .shift])
                .disabled(store == nil)
        }
    }
}

/// Help › SwiftCut Help opens the Help page in Settings.
struct HelpCommands: Commands {
    @Environment(\.openSettings) private var openSettings

    var body: some Commands {
        CommandGroup(replacing: .help) {
            Button("SwiftCut Help") {
                UserDefaults.standard.set(SettingsPage.help.rawValue, forKey: SettingsPage.storageKey)
                openSettings()
            }
            .keyboardShortcut("?", modifiers: .command)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppAppearance.saved.apply()
    }

    /// Launch shows the Welcome window instead of an empty project.
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { false }

    /// Clicking the Dock icon with no windows open brings back Welcome.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { WelcomeWindow.open?() }
        return false
    }
}
