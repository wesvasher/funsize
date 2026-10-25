import SwiftUI

/// One project's window. Owns the project's store and keeps it in step with the
/// saved document, so edits mark the window as changed and Undo/Redo work.
struct ProjectWindow: View {
    @Binding var document: ProjectDocument
    /// Where the project is saved; `nil` until it's saved.
    var fileURL: URL?
    @Environment(ExportManager.self) private var exporter
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var store: ProjectStore?

    var body: some View {
        Group {
            if let store {
                ContentView()
                    .environment(store)
                    .focusedSceneValue(store)
                    .onChange(of: store.projectFile) { _, file in
                        if document.file != file { document.file = file }
                    }
                    .onChange(of: document.file) { _, file in
                        store.apply(file)
                    }
                    .onChange(of: fileURL) { _, url in
                        store.projectURL = url
                    }
            } else {
                Color.clear
                    .frame(minWidth: 900, minHeight: 560)
            }
        }
        .onAppear {
            if store == nil {
                let store = ProjectStore(exporter: exporter)
                store.apply(document.file)
                store.selectInitialItem()
                store.projectURL = fileURL
                self.store = store
            }
            WelcomeWindow.open = { openWindow(id: WelcomeWindow.id) }
            dismissWindow(id: WelcomeWindow.id)
        }
        .onDisappear {
            // Closing the last project brings back the Welcome window.
            let open = WelcomeWindow.open
            DispatchQueue.main.async {
                if NSDocumentController.shared.documents.isEmpty { open?() }
            }
        }
    }
}
