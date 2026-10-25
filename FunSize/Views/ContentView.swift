import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(ProjectStore.self) private var store
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        @Bindable var store = store

        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 270, max: 400)
        } detail: {
            DetailView()
        }
        .toolbar { ExportToolbar() }
        .fileImporter(
            isPresented: $store.isImporting,
            allowedContentTypes: [.audiovisualContent],
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result {
                store.importAndSelect(urls, securityScoped: true)
            }
        }
        .frame(minWidth: 900, minHeight: 560)
        .alert("Export Folder Not Found", isPresented: Binding(
            get: { store.exportPrompt != nil },
            // Buttons answer first; this only catches the alert closing some other way.
            set: { if !$0 { DispatchQueue.main.async { store.answerPrompt(.cancel) } } }
        ), presenting: store.exportPrompt) { _ in
            Button("Choose Folder…") { store.answerPrompt(.chooseFolder) }
            Button("Open Settings…") { store.answerPrompt(.openSettings) }
            Button("Cancel", role: .cancel) { store.answerPrompt(.cancel) }
        } message: { prompt in
            if case .missingFolder(let path) = prompt {
                Text("FunSize can't find your export folder at \(path.abbreviatingWithTilde). It may have been moved, renamed, or be on a drive that isn't connected.\n\nChoose where to save this export, or set a new export folder in Settings.")
            }
        }
        .onAppear {
            store.openExportSettings = {
                UserDefaults.standard.set(SettingsPage.exportPresets.rawValue, forKey: SettingsPage.storageKey)
                openSettings()
            }
        }
    }
}

struct DetailView: View {
    @Environment(ProjectStore.self) private var store

    var body: some View {
        Group {
            if store.isTimelineSelected {
                TimelineDetailView()
            } else if store.selectedClips.count == 1, let clip = store.selectedClips.first {
                ClipDetailView(clip: clip)
            } else if store.selectedClips.count > 1 {
                MultipleClipsView(clips: store.selectedClips)
            } else {
                DropZoneView()
            }
        }
        // The window title is the project's name; the subtitle says what's showing.
        .navigationSubtitle(subtitle)
    }

    private var subtitle: String {
        if store.isTimelineSelected {
            return "Timeline · \(store.timeline.count) clips · \(store.timelineDuration.timecode)"
        }
        if store.selectedClips.count == 1 {
            let clip = store.selectedClips[0]
            return "\(clip.name) · \(clip.summary)"
        }
        if store.selectedClips.count > 1 { return "\(store.selectedClips.count) clips selected" }
        return ""
    }
}

/// Shown when nothing is selected: a big target for dropping files.
struct DropZoneView: View {
    @Environment(ProjectStore.self) private var store
    @State private var isTargeted = false

    var body: some View {
        ContentUnavailableView {
            Label("Drop Videos Here", systemImage: "film.stack")
        } description: {
            Text("Drag video files from Finder, then choose a format from Export.")
        } actions: {
            Button("Import Videos…") { store.isImporting = true }
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                .foregroundStyle(isTargeted ? Color.accentColor : Color.secondary.opacity(0.3))
                .padding(24)
        }
        .dropDestination(for: URL.self) { urls, _ in
            store.importAndSelect(urls)
            return true
        } isTargeted: { isTargeted = $0 }
    }
}

struct MultipleClipsView: View {
    @Environment(ProjectStore.self) private var store
    let clips: [Clip]

    var body: some View {
        ContentUnavailableView {
            Label("\(clips.count) Clips Selected", systemImage: "square.stack.3d.up")
        } description: {
            Text("Export saves each clip separately. To join them into one video, add them to the timeline.")
        } actions: {
            Button("Add to Timeline") {
                store.addToTimeline(clips)
                store.selection = [.timeline]
            }
        }
    }
}
