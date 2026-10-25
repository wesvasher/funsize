import AVKit
import AppKit

/// Plays a player full screen in its own window, using the standard macOS player controls.
/// Shares the preview's player, so effects and captions carry over. Esc (or the green
/// button) leaves full screen and closes the window.
@MainActor
enum FullScreenPlayer {
    static let windowID = NSUserInterfaceItemIdentifier("FunSize.fullScreenPlayer")

    private static var window: NSWindow?
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

        let playerView = AVPlayerView()
        playerView.player = player
        playerView.controlsStyle = .floating
        playerView.showsFullScreenToggleButton = false
        playerView.allowsPictureInPicturePlayback = false

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
        window.collectionBehavior = [.fullScreenPrimary]
        window.contentView = playerView
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
            // Leaving full screen ends full-screen playback.
            center.addObserver(forName: NSWindow.didExitFullScreenNotification, object: window, queue: .main) { _ in
                MainActor.assumeIsolated { close() }
            },
            center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
                MainActor.assumeIsolated { finish() }
            },
            center.addObserver(forName: NSWindow.didEnterFullScreenNotification, object: window, queue: .main) { _ in
            },
        ]
        // Esc leaves full screen.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let handled = MainActor.assumeIsolated {
                guard event.keyCode == 53, event.window === self.window else { return false }
                self.window?.toggleFullScreen(nil)
                return true
            }
            return handled ? nil : event
        }

        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(playerView)
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
        (window?.contentView as? AVPlayerView)?.player = nil
        window = nil
        pendingStart = nil
        let onClose = onClose
        self.onClose = nil
        onClose?()
    }
}
