import UniformTypeIdentifiers
import SwiftUI

struct SidebarView: View {
    @Environment(ProjectStore.self) private var store
    @State private var isTargeted = false
    /// Source videos whose subclips are hidden. New subclips show right away.
    @State private var collapsed: Set<UUID> = []

    var body: some View {
        @Bindable var store = store

        List(selection: $store.selection) {
            Section("Project") {
                Label("Timeline", systemImage: "rectangle.split.3x1")
                    .badge(store.timeline.count)
                    .tag(SidebarItem.timeline)
            }

            Section("Source Videos") {
                ForEach(store.clips) { clip in
                    let subclips = store.subclips(of: clip.id)
                    if subclips.isEmpty {
                        sourceRow(clip)
                    } else {
                        DisclosureGroup(isExpanded: expanded(clip.id)) {
                            ForEach(subclips) { subclip in
                                SubclipRow(subclip: subclip, clip: clip)
                                    .tag(SidebarItem.subclip(subclip.id))
                                    .draggable(subclip.dragURL) {
                                        SubclipRow(subclip: subclip, clip: clip).padding(6).frame(width: 240)
                                    }
                            }
                        } label: {
                            sourceRow(clip)
                        }
                    }
                }
            }
        }
        .contextMenu(forSelectionType: SidebarItem.self) { items in
            contextMenu(for: media(in: items))
        }
        .onDeleteCommand {
            store.removeSelectedMedia()
        }
        .dropDestination(for: URL.self) { urls, _ in
            store.importAndSelect(urls)
            return true
        } isTargeted: { isTargeted = $0 }
        .overlay {
            if isTargeted {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
                    .padding(4)
                    .allowsHitTesting(false)
            }
        }
        .safeAreaInset(edge: .bottom) {
            if !store.missingClips.isEmpty {
                MissingVideosBanner()
            } else if store.clips.isEmpty {
                Text("Drop videos here")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding()
            }
        }
        .toolbar {
            ToolbarItem {
                Button("Import Videos", systemImage: "plus") { store.isImporting = true }
                    .help("Import videos (⌘O)")
            }
        }
    }

    private func sourceRow(_ clip: Clip) -> some View {
        ClipRow(clip: clip, subclipCount: store.subclips(of: clip.id).count)
            .tag(SidebarItem.clip(clip.id))
            .draggable(clip.url) {
                ClipRow(clip: clip).padding(6).frame(width: 240)
            }
    }

    private func expanded(_ id: UUID) -> Binding<Bool> {
        Binding(
            get: { !collapsed.contains(id) },
            set: { if $0 { collapsed.remove(id) } else { collapsed.insert(id) } }
        )
    }

    /// The source videos and subclips among `items`, in sidebar order.
    private func media(in items: Set<SidebarItem>) -> [SidebarItem] {
        store.clips.flatMap { clip in
            [SidebarItem.clip(clip.id)] + store.subclips(of: clip.id).map { .subclip($0.id) }
        }
        .filter(items.contains)
    }

    @ViewBuilder
    private func contextMenu(for media: [SidebarItem]) -> some View {
        if !media.isEmpty {
            let clips = media.compactMap { if case .clip(let id) = $0 { store.clip(for: id) } else { nil } }
            let subclips = media.compactMap { if case .subclip(let id) = $0 { store.subclip(for: id) } else { nil } }

            Button("Add to Timeline", systemImage: "plus.rectangle.on.rectangle") {
                store.addToTimeline(media)
            }
            Menu("Export As") {
                ExportPresetMenuItems { preset in store.exportMedia(media, as: preset) }
            }
            Divider()
            let missing = clips.filter { $0.loadError != nil }
            if !missing.isEmpty {
                Button(missing.count == 1 ? "Locate Video…" : "Locate Videos…", systemImage: "magnifyingglass") {
                    MissingVideosBanner.locate(missing, in: store)
                }
            }
            if subclips.count == 1, clips.isEmpty, let subclip = subclips.first {
                Button("Show Source Video", systemImage: "film") {
                    collapsed.remove(subclip.sourceID)
                    store.selection = [.clip(subclip.sourceID)]
                }
            }
            Button("Show in Finder", systemImage: "folder") {
                let urls = clips.map(\.url) + subclips.compactMap { store.clip(for: $0.sourceID)?.url }
                NSWorkspace.shared.activateFileViewerSelecting(Array(Set(urls)))
            }
            Divider()
            Button(removeTitle(clips: clips.count, subclips: subclips.count), systemImage: "trash", role: .destructive) {
                store.removeSubclips(Set(subclips.map(\.id)))
                store.removeClips(Set(clips.map(\.id)))
            }
        }
    }

    private func removeTitle(clips: Int, subclips: Int) -> String {
        if clips == 0 { return subclips == 1 ? "Delete Subclip" : "Delete \(subclips) Subclips" }
        return "Remove from Project"
    }
}

/// Says some source videos can't be opened, with a button to find them.
struct MissingVideosBanner: View {
    @Environment(ProjectStore.self) private var store

    var body: some View {
        let count = store.missingClips.count
        VStack(alignment: .leading, spacing: 6) {
            Label(count == 1 ? "1 video can't be opened" : "\(count) videos can't be opened",
                  systemImage: "exclamationmark.triangle.fill")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.orange)
            Text("Find them once to give SwiftCut access. You can select several files at once.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Locate Videos…") { Self.locate(store.missingClips, in: store) }
                .controlSize(.small)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        .padding(10)
    }

    /// Asks for the missing files and relinks the ones chosen.
    static func locate(_ missing: [Clip], in store: ProjectStore) {
        guard !missing.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.audiovisualContent]
        panel.directoryURL = missing[0].url.deletingLastPathComponent()
        panel.prompt = "Choose"
        panel.message = missing.count == 1
            ? "Find “\(missing[0].url.lastPathComponent)” and click Choose."
            : "Find the missing videos (\(missing.map(\.url.lastPathComponent).joined(separator: ", "))). Select all of them and click Choose."
        let choose = { (response: NSApplication.ModalResponse) in
            guard response == .OK else { return }
            store.relink(panel.urls, preferring: missing.count == 1 ? missing[0] : nil)
        }
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: choose)
        } else {
            choose(panel.runModal())
        }
    }
}

/// A subclip under its source video: picture at its in point, name, length and range.
struct SubclipRow: View {
    let subclip: Subclip
    let clip: Clip

    var body: some View {
        let range = subclip.range(in: clip.duration)
        HStack(spacing: 10) {
            ClipThumbnail(clip: clip, time: range.lowerBound)
                .frame(width: 48, height: 27)
                .clipShape(RoundedRectangle(cornerRadius: 3))

            VStack(alignment: .leading, spacing: 2) {
                Text(subclip.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Label("\((range.upperBound - range.lowerBound).timecode) · \(range.lowerBound.preciseTimecode)–\(range.upperBound.preciseTimecode)",
                      systemImage: "scissors")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 1)
        .help("Subclip of \(clip.name)")
    }
}

/// A source video: picture, name, and its details or marked range.
struct ClipRow: View {
    let clip: Clip
    var subclipCount = 0

    var body: some View {
        HStack(spacing: 10) {
            ClipThumbnail(clip: clip)
                .frame(width: 64, height: 36)
                .clipShape(RoundedRectangle(cornerRadius: 4))

            VStack(alignment: .leading, spacing: 2) {
                Text(clip.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Group {
                    if let error = clip.loadError {
                        Label(error, systemImage: "exclamationmark.triangle")
                    } else if clip.isLoaded && clip.hasMarks {
                        Label("Marked \((clip.markedRange.upperBound - clip.markedRange.lowerBound).timecode) of \(clip.duration.timecode)", systemImage: "scissors")
                    } else if clip.isLoaded && subclipCount > 0 {
                        Text("\(clip.summary) · \(subclipCount) subclip\(subclipCount == 1 ? "" : "s")")
                    } else if clip.isLoaded {
                        Text(clip.summary)
                    } else {
                        Text("Loading…")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }
}

struct ClipThumbnail: View {
    let clip: Clip
    var time: Double?

    var body: some View {
        ZStack {
            Rectangle().fill(.quaternary)
            if let image = time.flatMap(clip.thumbnail(near:)) ?? clip.poster {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .scaledToFill()
            } else if clip.isLoaded && !clip.hasVideo {
                Image(systemName: "waveform")
                    .foregroundStyle(.secondary)
            } else if !clip.isLoaded && clip.loadError == nil {
                ProgressView().controlSize(.small)
            }
        }
        .clipped()
    }
}
