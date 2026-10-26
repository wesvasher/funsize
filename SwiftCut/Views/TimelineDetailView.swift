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
            TimelinePreview(playback: playback)
            Divider()
            TimelineEditorView(playback: playback)
                .frame(height: 180)
        }
        .spaceBarPlaysAndPauses { playback.togglePlayPause() }
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

/// Plays the combined timeline, rebuilding it whenever the timeline changes. Above it, the
/// video toolbar (shared with the clip viewer) with the timeline's play button and timecode.
private struct TimelinePreview: View {
    @Environment(ProjectStore.self) private var store
    let playback: TimelinePlayback
    private var player: AVPlayer { playback.player }
    @State private var buildError: String?
    @State private var sourceID = UUID()
    @State private var zoom = ViewerZoom.fit
    @State private var pan = CGSize.zero
    @State private var toast: Toast?
    /// The part of the picture on screen, and its size there in pixels, for Export Images.
    @State private var visibleView = (fraction: CGRect(x: 0, y: 0, width: 1, height: 1), pixels: CGSize.zero)
    @State private var isExportingImages = false

    var body: some View {
        VStack(spacing: 0) {
            VideoToolbar(pictureSize: store.timeline.isEmpty ? nil : store.timelineFrameSize, zoom: $zoom,
                         canCopy: !store.timeline.isEmpty && buildError == nil,
                         isExporting: isExportingImages, copyFrame: copyFrame, exportImages: exportImages) {
                Button(playback.isPlaying ? "Pause" : "Play", systemImage: playback.isPlaying ? "pause.fill" : "play.fill",
                       action: playback.togglePlayPause)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .frame(width: 16)
                    .disabled(store.timeline.isEmpty)
                    .help("Play or pause the timeline (Space)")
                Text("\(playback.time.preciseTimecode) / \(store.timelineDuration.preciseTimecode)")
                    .font(.callout.monospacedDigit())
                    .help("Playhead position / timeline length")
                Divider().frame(height: 14)
            }
            Divider()
            ZStack {
                if store.timeline.isEmpty {
                    ContentUnavailableView(
                        "Timeline Is Empty",
                        systemImage: "rectangle.split.3x1",
                        description: Text("Drag clips from the sidebar or Finder into the timeline below.")
                    )
                } else {
                    ZoomableVideoView(player: player, togglePlayPause: playback.togglePlayPause,
                                      pictureSize: store.timelineFrameSize, zoom: zoom, pan: $pan,
                                      zoomToFit: { zoom = .fit }, reportView: { visibleView = ($0, $1) })
                    if let buildError {
                        ContentUnavailableView("Can't Preview", systemImage: "exclamationmark.triangle", description: Text(buildError))
                            .background(.regularMaterial)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .toast($toast)
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

    // MARK: Copy Frame and Export Images

    /// The frame on screen, through the timeline's layout (size, fit).
    private func grabFrame() async throws -> CGImage {
        guard let item = player.currentItem else { throw EnhanceError.failed("There's no video frame to copy.") }
        return try await FrameClipboard.currentFrame(of: item)
    }

    /// 1-based frame number at the playhead.
    private var frameNumber: Int {
        let duration = player.currentItem?.videoComposition?.frameDuration
        let fps = duration.map { $0.isNumeric && $0.seconds > 0 ? 1 / $0.seconds : 30 } ?? 30
        return Int((playback.time * fps).rounded(.down)) + 1
    }

    private func copyFrame() {
        let describe = "Timeline frame \(frameNumber.formatted()) (\(playback.time.preciseTimecode))"
        Task { toast = await VideoFrameActions.copy(grab: grabFrame, describe: describe) }
    }

    private func exportImages() {
        let baseName = "Timeline Frame \(frameNumber)"
        let view = visibleView, zoomTitle = zoom.title
        isExportingImages = true
        Task {
            defer { isExportingImages = false }
            if let result = await VideoFrameActions.exportImages(grab: grabFrame, baseName: baseName,
                                                                 view: view, zoomTitle: zoomTitle, store: store) {
                toast = result
            }
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
            let result = try await CompositionBuilder.build(segments, settings: store.timelineSettings)
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
    private(set) var isPlaying = false
    @ObservationIgnored private var observer: Any?
    @ObservationIgnored private var statusObservation: NSKeyValueObservation?

    init() {
        // Also called when the time jumps (seeking), not just while playing.
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, time.isNumeric else { return }
                self.time = time.seconds
            }
        }
        statusObservation = player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] player, _ in
            let playing = player.timeControlStatus != .paused
            DispatchQueue.main.async { self?.isPlaying = playing }
        }
    }

    func togglePlayPause() {
        guard let item = player.currentItem else { return }
        if player.rate != 0 {
            player.pause()
            return
        }
        // Start over if it's at the end.
        if item.duration.isNumeric, player.currentTime().seconds >= item.duration.seconds - 0.05 {
            player.seek(to: .zero)
        }
        player.play()
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
