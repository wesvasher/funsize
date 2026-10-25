import AVKit
import SwiftUI

struct TimelineDetailView: View {
    @State private var isShowingInspector = true

    var body: some View {
        VStack(spacing: 0) {
            TimelinePreview()
            Divider()
            TimelineEditorView()
                .frame(height: 180)
        }
        // No minimum size beside the inspector, or the split view re-layouts in a loop (see ClipDetailView).
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        .clipped()
        .inspector(isPresented: $isShowingInspector) {
            TimelineInspectorView()
                .inspectorColumnWidth(min: 240, ideal: 270, max: 360)
        }
        .toolbar {
            ToolbarItem {
                Button("Inspector", systemImage: "sidebar.trailing") {
                    isShowingInspector.toggle()
                }
                .help("Show or hide the trim inspector")
            }
        }
    }
}

/// Plays the combined timeline, rebuilding it whenever the timeline changes.
private struct TimelinePreview: View {
    @Environment(ProjectStore.self) private var store
    @State private var player = AVPlayer()
    @State private var buildError: String?

    var body: some View {
        ZStack {
            if store.timeline.isEmpty {
                ContentUnavailableView(
                    "Timeline Is Empty",
                    systemImage: "rectangle.split.3x1",
                    description: Text("Drag clips from the sidebar or Finder into the timeline below.")
                )
            } else {
                PlayerView(player: player)
                    .background(.black)
                if let buildError {
                    ContentUnavailableView("Can't Preview", systemImage: "exclamationmark.triangle", description: Text(buildError))
                        .background(.regularMaterial)
                }
            }
        }
        .task(id: store.timelineSignature) {
            await rebuild()
        }
        .onDisappear { player.pause() }
    }

    private func rebuild() async {
        // Wait a moment so dragging a trim slider doesn't rebuild on every tick.
        try? await Task.sleep(for: .milliseconds(250))
        guard !Task.isCancelled else { return }

        let segments = store.timelineSegments
        guard !segments.isEmpty else {
            player.replaceCurrentItem(with: nil)
            return
        }
        do {
            let result = try await CompositionBuilder.build(segments)
            guard !Task.isCancelled else { return }
            let resumeAt = player.currentTime()
            let item = AVPlayerItem(asset: result.composition)
            item.videoComposition = result.videoComposition
            player.replaceCurrentItem(with: item)
            if resumeAt.seconds < result.duration {
                await player.seek(to: resumeAt)
            }
            buildError = nil
        } catch {
            buildError = error.localizedDescription
        }
    }
}
