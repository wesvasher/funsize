import SwiftUI

struct SidebarView: View {
    @Environment(ProjectStore.self) private var store
    @State private var isTargeted = false

    var body: some View {
        @Bindable var store = store

        List(selection: $store.selection) {
            Section("Project") {
                Label("Timeline", systemImage: "rectangle.split.3x1")
                    .badge(store.timeline.count)
                    .tag(SidebarItem.timeline)
            }

            Section("Media") {
                ForEach(store.clips) { clip in
                    ClipRow(clip: clip)
                        .tag(SidebarItem.clip(clip.id))
                        .draggable(clip.url) {
                            ClipRow(clip: clip).padding(6).frame(width: 240)
                        }
                }
            }
        }
        .contextMenu(forSelectionType: SidebarItem.self) { items in
            contextMenu(for: clips(in: items))
        }
        .onDeleteCommand {
            store.removeClips(Set(store.selectedClips.map(\.id)))
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
            if store.clips.isEmpty {
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

    private func clips(in items: Set<SidebarItem>) -> [Clip] {
        store.clips.filter { items.contains(.clip($0.id)) }
    }

    @ViewBuilder
    private func contextMenu(for clips: [Clip]) -> some View {
        if !clips.isEmpty {
            Button("Add to Timeline", systemImage: "plus.rectangle.on.rectangle") {
                store.addToTimeline(clips)
            }
            Menu("Export As") {
                ForEach(ExportFormat.allCases) { format in
                    Button(format.title, systemImage: format.systemImage) {
                        clips.forEach { store.exportClip($0, as: format) }
                    }
                }
            }
            Divider()
            Button("Show in Finder", systemImage: "folder") {
                NSWorkspace.shared.activateFileViewerSelecting(clips.map(\.url))
            }
            Divider()
            Button("Remove", systemImage: "trash", role: .destructive) {
                store.removeClips(Set(clips.map(\.id)))
            }
        }
    }
}

struct ClipRow: View {
    let clip: Clip

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
