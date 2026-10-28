import AppKit
import SwiftUI

/// The bar above a video viewer (clip viewer and timeline): the picture size, then Copy Frame,
/// Export Images, quality, zoom, and the master volume on the right. `leading` holds controls only one viewer has.
struct VideoToolbar<Leading: View>: View {
    /// The picture's size in pixels, or `nil` if not known yet.
    let pictureSize: CGSize?
    @Binding var zoom: ViewerZoom
    @Binding var quality: PreviewQuality
    /// The Quality menu's tooltip.
    let qualityHelp: String
    let canCopy: Bool
    let isExporting: Bool
    let copyFrame: () -> Void
    let exportImages: () -> Void
    @ViewBuilder var leading: () -> Leading

    var body: some View {
        HStack(spacing: 12) {
            leading()
            if let pictureSize, pictureSize != .zero {
                Text("\(Int(pictureSize.width)) × \(Int(pictureSize.height))")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button("Copy Frame", systemImage: "doc.on.doc", action: copyFrame)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .disabled(!canCopy)
                .help("Copy the frame on screen to the clipboard, at full size")
            Button("Export Images", systemImage: "photo.badge.arrow.down", action: exportImages)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .disabled(!canCopy || isExporting)
                .help("Save the full frame, and the part in view, as PNG images in the project's folder")
            PreviewQualityMenu(quality: $quality)
                .help(qualityHelp)
            ViewerZoomControl(zoom: $zoom)
            Divider().frame(height: 14)
            MonitorVolumeControl()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(.bar)
    }
}

extension VideoToolbar where Leading == EmptyView {
    init(pictureSize: CGSize?, zoom: Binding<ViewerZoom>, quality: Binding<PreviewQuality>, qualityHelp: String,
         canCopy: Bool, isExporting: Bool, copyFrame: @escaping () -> Void, exportImages: @escaping () -> Void) {
        self.init(pictureSize: pictureSize, zoom: zoom, quality: quality, qualityHelp: qualityHelp,
                  canCopy: canCopy, isExporting: isExporting,
                  copyFrame: copyFrame, exportImages: exportImages, leading: { EmptyView() })
    }
}

/// Picks the preview quality: full, or a smaller picture that plays more easily.
private struct PreviewQualityMenu: View {
    @Binding var quality: PreviewQuality

    var body: some View {
        Menu {
            Picker("Preview Quality", selection: $quality) {
                ForEach(PreviewQuality.allCases) { choice in
                    Text(choice.menuTitle).tag(choice)
                }
            }
            .pickerStyle(.inline)
        } label: {
            Label(quality.title, systemImage: quality == .full ? "sparkles.tv" : "gauge.with.dots.needle.33percent")
                .labelStyle(.titleAndIcon)
                .font(.callout.monospacedDigit())
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityLabel("Preview Quality: \(quality.menuTitle)")
    }
}

/// Copy Frame and Export Images, shared by the viewers. Each returns the toast to show.
enum VideoFrameActions {
    /// Copies the frame from `grab`. `describe` says which frame, e.g. "Frame 12 (00:00:00:11)".
    static func copy(grab: () async throws -> CGImage, describe: String, suffix: String = ", as shown in the viewer.") async -> Toast {
        do {
            let image = try await grab()
            try await FrameClipboard.copy(image)
            return Toast(systemImage: "doc.on.clipboard", title: "Frame Copied to Clipboard",
                         detail: "\(describe) at \(image.width) × \(image.height)\(suffix) Paste it into any app.")
        } catch {
            return Toast(systemImage: "exclamationmark.triangle.fill", title: "Couldn't Copy Frame",
                         detail: error.localizedDescription, isError: true)
        }
    }

    /// Saves two PNGs next to the project: the whole frame at full size, and the part in the
    /// viewer as it looks on screen (`view`: which part, and its on-screen size in pixels).
    /// `nil` when the user cancelled choosing a folder.
    static func exportImages(grab: () async throws -> CGImage, baseName: String,
                             view: (fraction: CGRect, pixels: CGSize), zoomTitle: String,
                             store: ProjectStore) async -> Toast? {
        do {
            // Grab the frame first, so it's the one on screen when the button was clicked.
            let image = try await grab()
            guard let folder = await store.projectFolderForImages() else { return nil }
            let pixels = view.pixels == .zero ? CGSize(width: image.width, height: image.height) : view.pixels
            let fraction = view.fraction
            let saved = try await Task.detached(priority: .userInitiated) {
                let viewImage = try FrameClipboard.crop(image, to: fraction, size: pixels)
                return (try FrameClipboard.savePNG(image, named: baseName, in: folder),
                        try FrameClipboard.savePNG(viewImage, named: "\(baseName) View \(zoomTitle)", in: folder))
            }.value
            return Toast(
                systemImage: "photo.on.rectangle",
                title: "Exported 2 Images",
                detail: "“\(saved.0.lastPathComponent)” (\(image.width) × \(image.height)) and “\(saved.1.lastPathComponent)” (the view) are in “\(folder.lastPathComponent)”.",
                action: ToastAction(title: "Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([saved.0, saved.1])
                }
            )
        } catch {
            return Toast(systemImage: "exclamationmark.triangle.fill", title: "Couldn't Export Images",
                         detail: error.localizedDescription, isError: true)
        }
    }
}
