import AVKit
import SwiftUI

/// The system video player (AVPlayerView) with standard inline controls.
///
/// Used instead of SwiftUI's `VideoPlayer`, which crashes on load in macOS 27.0.
struct PlayerView: NSViewRepresentable {
    let player: AVPlayer
    var showsControls = true

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = showsControls ? .inline : .none
        view.showsFullScreenToggleButton = true
        view.allowsPictureInPicturePlayback = true
        view.player = player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player {
            view.player = player
        }
    }
}
