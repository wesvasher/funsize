import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(ProjectStore.self) private var store

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
        .navigationTitle(title)
        .navigationSubtitle(subtitle)
    }

    private var title: String {
        if store.isTimelineSelected { return "Timeline" }
        if store.selectedClips.count == 1 { return store.selectedClips[0].name }
        return "FunSize"
    }

    private var subtitle: String {
        if store.isTimelineSelected {
            return "\(store.timeline.count) clips · \(store.timelineDuration.timecode)"
        }
        if store.selectedClips.count == 1 { return store.selectedClips[0].summary }
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
