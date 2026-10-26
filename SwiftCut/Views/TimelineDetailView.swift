import AVKit
import SwiftUI

struct TimelineDetailView: View {
    @Environment(ProjectStore.self) private var store
    @State private var isShowingInspector = true
    /// Shared by the preview and the timeline strip, which draws the playhead.
    @State private var playback = TimelinePlayback()

    /// The inspector, hidden while both sidebars are hidden (⌘.). Showing it by hand
    /// brings the left sidebar back too.
    private var inspectorShown: Binding<Bool> {
        Binding(
            get: { isShowingInspector && !store.sidebarsHidden },
            set: { show in
                if show, store.sidebarsHidden { store.sidebarsHidden = false }
                isShowingInspector = show
            }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            TimelinePreview(player: playback.player)
            Divider()
            TimelineEditorView(playback: playback)
                .frame(height: 180)
        }
        // No minimum size beside the inspector, or the split view re-layouts in a loop (see ClipDetailView).
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        .clipped()
        .inspector(isPresented: inspectorShown) {
            TimelineInspectorView()
                .inspectorColumnWidth(300)
        }
        .toolbar {
            ToolbarItem {
                Button("Inspector", systemImage: "sidebar.trailing") {
                    inspectorShown.wrappedValue.toggle()
                }
                .help("Show or hide the trim inspector")
            }
        }
    }
}

/// Plays the combined timeline, rebuilding it whenever the timeline changes.
private struct TimelinePreview: View {
    @Environment(ProjectStore.self) private var store
    let player: AVPlayer
    @State private var buildError: String?
    @State private var sourceID = UUID()

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
        .onChange(of: store.timeline.isEmpty, initial: true) { _, isEmpty in
            if isEmpty {
                store.clearFullScreenSource(owner: sourceID)
            } else {
                let player = player
                store.setFullScreenSource(.init(owner: sourceID) {
                    FullScreenPlayer.present(player: player, title: "Timeline") {
                        // Start over if it's at the end.
                        if let item = player.currentItem, item.duration.isNumeric,
                           player.currentTime().seconds >= item.duration.seconds - 0.05 {
                            player.seek(to: .zero)
                        }
                        player.play()
                    } onClose: {
                        player.pause()
                    }
                })
            }
        }
        .onDisappear {
            player.pause()
            store.clearFullScreenSource(owner: sourceID)
        }
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

/// The timeline's player and where it is, for the playhead.
@Observable
final class TimelinePlayback {
    let player = AVPlayer()
    /// Seconds from the start of the timeline.
    private(set) var time: Double = 0
    @ObservationIgnored private var observer: Any?

    init() {
        // Also called when the time jumps (seeking), not just while playing.
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, time.isNumeric else { return }
                self.time = time.seconds
            }
        }
    }

    /// Moves the playhead (pausing playback), for scrubbing.
    func scrub(to seconds: Double) {
        player.pause()
        time = seconds
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    isolated deinit {
        if let observer { player.removeTimeObserver(observer) }
    }
}
