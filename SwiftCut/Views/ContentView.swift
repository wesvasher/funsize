import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(ProjectStore.self) private var store
    @Environment(\.openSettings) private var openSettings
    @State private var columnVisibility = NavigationSplitViewVisibility.all

    var body: some View {
        @Bindable var store = store

        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 270, max: 400)
        } detail: {
            DetailView()
        }
        .toolbar { ExportToolbar() }
        .onChange(of: store.sidebarsHidden) { _, hidden in
            withAnimation { columnVisibility = hidden ? .detailOnly : .all }
        }
        .onChange(of: columnVisibility) { _, visibility in
            // Showing the sidebar by hand brings the inspector back too.
            if visibility != .detailOnly, store.sidebarsHidden { store.sidebarsHidden = false }
        }
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
                Text("SwiftCut can't find your export folder at \(path.abbreviatingWithTilde). It may have been moved, renamed, or be on a drive that isn't connected.\n\nChoose where to save this export, or set a new export folder in Settings.")
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
            } else if let (clip, subclip) = store.singleSelectedMedia {
                // One view for a source and its subclips, so switching between them keeps the player.
                ClipDetailView(clip: clip, subclip: subclip)
            } else if store.selectedMedia.count > 1 {
                MultipleClipsView(media: store.selectedMedia)
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
        if let (clip, subclip) = store.singleSelectedMedia {
            if let subclip {
                let range = subclip.range(in: clip.duration)
                return "\(subclip.name) · Subclip of \(clip.name) · \((range.upperBound - range.lowerBound).timecode)"
            }
            return "\(clip.name) · \(clip.summary)"
        }
        if store.selectedMedia.count > 1 { return "\(store.selectedMedia.count) items selected" }
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
    /// Source videos and subclips.
    let media: [SidebarItem]

    var body: some View {
        ContentUnavailableView {
            Label("\(media.count) Items Selected", systemImage: "square.stack.3d.up")
        } description: {
            Text("Export saves each one separately. To join them into one video, add them to the timeline.")
        } actions: {
            Button("Add to Timeline") {
                store.addToTimeline(media)
                store.selection = [.timeline]
            }
        }
    }
}
