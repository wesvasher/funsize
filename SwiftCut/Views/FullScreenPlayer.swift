import AVKit
import AppKit
import SwiftUI

/// Plays a player full screen in its own window with a slim control strip along the bottom
/// (play/pause, a full-width progress bar, time, and exit) instead of the system controls.
/// Shares the preview's player, so effects and captions carry over.
/// Space plays or pauses; Esc leaves full screen and closes the window.
@MainActor
enum FullScreenPlayer {
    static let windowID = NSUserInterfaceItemIdentifier("SwiftCut.fullScreenPlayer")

    private static var window: NSWindow?
    private static var transport: FullScreenTransport?
    private static var observers: [NSObjectProtocol] = []
    private static var keyMonitor: Any?
    private static var onClose: (@MainActor () -> Void)?
    private static var pendingStart: (@MainActor () -> Void)?

    private static func startIfNeeded() {
        let start = pendingStart
        pendingStart = nil
        start?()
    }

    static var isShowing: Bool { window != nil }

    /// Shows `player` full screen. `start` begins playback; `onClose` runs when it closes.
    static func present(player: AVPlayer, title: String, start: @escaping @MainActor () -> Void, onClose: @escaping @MainActor () -> Void) {
        // Only one at a time: close any earlier one right away (no exit animation).
        window?.close()

        let transport = FullScreenTransport(player: player)
        transport.exit = { close() }
        self.transport = transport

        let screen = NSApp.keyWindow?.screen ?? NSScreen.main
        let window = NSWindow(
            contentRect: screen?.frame ?? CGRect(x: 0, y: 0, width: 1280, height: 720),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.identifier = windowID
        window.title = title
        window.titlebarAppearsTransparent = true
        window.backgroundColor = .black
        window.isReleasedWhenClosed = false
        window.acceptsMouseMovedEvents = true
        window.collectionBehavior = [.fullScreenPrimary]
        window.contentView = FullScreenContentView(player: player, transport: transport)
        self.window = window
        self.onClose = onClose

        // Start once the window is full screen, so the first frames aren't missed,
        // or after a moment if the switch to full screen doesn't happen.
        pendingStart = start
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            MainActor.assumeIsolated {
                if self.window === window { startIfNeeded() }
            }
        }

        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: NSWindow.didEnterFullScreenNotification, object: window, queue: .main) { _ in
                MainActor.assumeIsolated { startIfNeeded() }
            },
            // Leaving full screen ends full-screen playback.
            center.addObserver(forName: NSWindow.didExitFullScreenNotification, object: window, queue: .main) { _ in
                MainActor.assumeIsolated { close() }
            },
            center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
                MainActor.assumeIsolated { finish() }
            },
        ]
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .mouseMoved]) { event in
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard event.window === self.window, let transport = self.transport else { return false }
                if event.type == .mouseMoved {
                    transport.wake()
                    return false
                }
                switch event.keyCode {
                case 53:  // Esc
                    close()
                case 49:  // Space
                    if !event.isARepeat { transport.togglePlayPause() }
                    transport.wake()
                default:
                    return false
                }
                return true
            }
            return handled ? nil : event
        }

        window.makeKeyAndOrderFront(nil)
        window.toggleFullScreen(nil)
    }

    /// Leaves full screen (if needed) and closes the window.
    static func close() {
        guard let window else { return }
        if window.styleMask.contains(.fullScreen) {
            window.toggleFullScreen(nil)  // closes when the exit finishes
        } else {
            window.close()
        }
    }

    private static func finish() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        transport?.stop()
        transport = nil
        (window?.contentView as? FullScreenContentView)?.detach()
        window = nil
        pendingStart = nil
        NSCursor.setHiddenUntilMouseMoves(false)
        let onClose = onClose
        self.onClose = nil
        onClose?()
    }
}

/// The picture with the control strip on top of its bottom edge.
private final class FullScreenContentView: NSView {
    private let playerView = AVPlayerView()

    init(player: AVPlayer, transport: FullScreenTransport) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor

        playerView.player = player
        playerView.controlsStyle = .none
        playerView.showsFullScreenToggleButton = false
        playerView.allowsPictureInPicturePlayback = false
        playerView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(playerView)

        let controls = NSHostingView(rootView: FullScreenControls(transport: transport))
        controls.translatesAutoresizingMaskIntoConstraints = false
        addSubview(controls)

        NSLayoutConstraint.activate([
            playerView.leadingAnchor.constraint(equalTo: leadingAnchor),
            playerView.trailingAnchor.constraint(equalTo: trailingAnchor),
            playerView.topAnchor.constraint(equalTo: topAnchor),
            playerView.bottomAnchor.constraint(equalTo: bottomAnchor),
            controls.leadingAnchor.constraint(equalTo: leadingAnchor),
            controls.trailingAnchor.constraint(equalTo: trailingAnchor),
            controls.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func detach() {
        playerView.player = nil
    }
}

/// Playback state for the control strip, plus dimming it when the mouse rests.
@Observable
final class FullScreenTransport {
    let player: AVPlayer
    var currentTime: Double = 0
    var duration: Double = 0
    var isPlaying = false
    /// True shortly after the mouse moves; the strip dims when false.
    var isAwake = true
    /// Dragging the progress bar.
    var isScrubbing = false
    @ObservationIgnored var exit: (() -> Void)?

    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var statusObservation: NSKeyValueObservation?
    @ObservationIgnored private var durationObservation: NSKeyValueObservation?
    @ObservationIgnored private var idleTask: Task<Void, Never>?

    init(player: AVPlayer) {
        self.player = player
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self else { return }
                if !self.isScrubbing, time.isNumeric { self.currentTime = time.seconds }
                self.refreshDuration()
            }
        }
        durationObservation = player.observe(\.currentItem?.duration, options: [.initial, .new]) { [weak self] _, _ in
            Task { @MainActor in self?.refreshDuration() }
        }
        statusObservation = player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] player, _ in
            let playing = player.timeControlStatus != .paused
            Task { @MainActor in self?.isPlaying = playing }
        }
        wake()
    }

    private func refreshDuration() {
        if let item = player.currentItem, item.duration.isNumeric, item.duration.seconds != duration {
            duration = item.duration.seconds
        }
    }

    func stop() {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        statusObservation = nil
        durationObservation = nil
        idleTask?.cancel()
    }

    func togglePlayPause() {
        if player.timeControlStatus == .paused {
            // Start over from the beginning if it's at the end.
            if duration > 0, currentTime >= duration - 0.05 { seek(to: 0) }
            player.play()
        } else {
            player.pause()
        }
    }

    func seek(to seconds: Double) {
        refreshDuration()
        currentTime = min(max(0, seconds), duration)
        player.seek(to: CMTime(seconds: currentTime, preferredTimescale: 90_000),
                    toleranceBefore: .zero, toleranceAfter: .zero)
    }

    /// Shows the strip at full strength, then dims it (and hides the cursor) after a rest.
    func wake() {
        if !isAwake { isAwake = true }
        idleTask?.cancel()
        idleTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled, let self, !self.isScrubbing else { return }
            self.isAwake = false
            NSCursor.setHiddenUntilMouseMoves(true)
        }
    }
}

/// The slim strip: play/pause, a full-width progress bar, time, and exit.
struct FullScreenControls: View {
    let transport: FullScreenTransport
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 10) {
            StripButton(systemImage: transport.isPlaying ? "pause.fill" : "play.fill",
                        help: transport.isPlaying ? "Pause (Space)" : "Play (Space)") {
                transport.togglePlayPause()
            }

            ProgressBar(transport: transport)

            Text("\(Self.time(transport.currentTime)) / \(Self.time(transport.duration))")
                .font(.system(size: 10, weight: .medium).monospacedDigit())
                .foregroundStyle(.white.opacity(0.7))
                .lineLimit(1)

            StripButton(systemImage: "arrow.down.right.and.arrow.up.left", help: "Exit Full Screen (Esc)") {
                transport.exit?()
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 8)
        .background(
            // A faint shade so the controls read on bright pictures.
            LinearGradient(colors: [.clear, .black.opacity(0.45)], startPoint: .top, endPoint: .bottom)
                .allowsHitTesting(false)
        )
        .opacity(transport.isAwake || isHovering || transport.isScrubbing ? 1 : 0.12)
        .animation(.easeInOut(duration: transport.isAwake ? 0.15 : 0.8), value: transport.isAwake)
        .onHover { hovering in
            isHovering = hovering
            if hovering { transport.wake() }
        }
    }

    static func time(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        let total = Int(seconds)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

private struct StripButton: View {
    let systemImage: String
    let help: String
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(isHovering ? 1 : 0.75))
                .frame(width: 22, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { isHovering = $0 }
    }
}

/// A thin full-width bar; click or drag anywhere on it to move through the video.
private struct ProgressBar: View {
    let transport: FullScreenTransport
    @State private var isHovering = false

    var body: some View {
        GeometryReader { geo in
            let fraction = transport.duration > 0 ? min(max(transport.currentTime / transport.duration, 0), 1) : 0
            let thick: CGFloat = isHovering || transport.isScrubbing ? 5 : 3
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.22))
                Capsule().fill(.white.opacity(0.85))
                    .frame(width: max(thick, geo.size.width * fraction))
            }
            .frame(height: thick)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        transport.isScrubbing = true
                        transport.seek(to: transport.duration * min(max(value.location.x / geo.size.width, 0), 1))
                    }
                    .onEnded { _ in
                        transport.isScrubbing = false
                        transport.wake()
                    }
            )
            .animation(.easeOut(duration: 0.12), value: thick)
        }
        .frame(height: 18)
        .onHover { isHovering = $0 }
    }
}
