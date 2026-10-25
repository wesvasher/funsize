import SwiftUI

@main
struct FunSizeApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @State private var exporter: ExportManager
    @State private var store: ProjectStore

    init() {
        let exporter = ExportManager()
        _exporter = State(initialValue: exporter)
        _store = State(initialValue: ProjectStore(exporter: exporter))
    }

    var body: some Scene {
        Window("FunSize", id: "main") {
            ContentView()
                .environment(store)
                .environment(exporter)
        }
        .defaultSize(width: 1200, height: 760)
        .commands {
            PlaybackCommands()
            CommandGroup(replacing: .newItem) {
                Button("Import Videos…") { store.isImporting = true }
                    .keyboardShortcut("o")
            }
        }

        Settings {
            SettingsView()
                .environment(exporter)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
