import AVKit
import SwiftUI

struct ClipDetailView: View {
    @Environment(ProjectStore.self) private var store
    let clip: Clip
    @State private var player = AVPlayer()

    var body: some View {
        VStack(spacing: 0) {
            VideoPlayer(player: player)
                .background(.black)

            Divider()

            HStack(spacing: 24) {
                InfoItem(title: "Duration", value: clip.duration.timecode)
                if clip.hasVideo {
                    InfoItem(title: "Resolution", value: "\(Int(clip.displaySize.width))×\(Int(clip.displaySize.height))")
                    InfoItem(title: "Frame Rate", value: String(format: "%.3g fps", clip.frameRate))
                }
                InfoItem(title: "File Size", value: clip.fileSize.formatted(.byteCount(style: .file)))
                Spacer()
                Button("Add to Timeline", systemImage: "plus.rectangle.on.rectangle") {
                    store.addToTimeline([clip])
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(.bar)
        }
        .onChange(of: clip.id, initial: true) {
            player.replaceCurrentItem(with: AVPlayerItem(url: clip.url))
        }
        .onDisappear { player.pause() }
    }
}

private struct InfoItem: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .monospacedDigit()
        }
    }
}
