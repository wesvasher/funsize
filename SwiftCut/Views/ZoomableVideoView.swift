import AVFoundation
import AppKit
import SwiftUI

/// The video at the chosen zoom, cut off at the viewer's edges. When the picture is bigger
/// than the viewer, Shift-drag moves it around. Click to play or pause.
struct ZoomableVideoView: View {
    let controller: ClipPlayerController
    /// The picture's size in pixels.
    let pictureSize: CGSize
    let zoom: ViewerZoom
    /// Where the picture sits, as a fraction of its on-screen size from centered.
    /// A fraction, so zooming keeps the same part of the picture in the middle.
    @Binding var pan: CGSize

    @Environment(\.displayScale) private var displayScale
    @State private var dragStart: CGSize?
    @State private var isShiftDown = false

    var body: some View {
        GeometryReader { geometry in
            let viewport = geometry.size
            let display = zoom.displaySize(picture: pictureSize, viewport: viewport, pixelsPerPoint: displayScale)
            let offset = ViewerZoom.clamp(CGSize(width: pan.width * display.width, height: pan.height * display.height),
                                          display: display, viewport: viewport)
            let limit = ViewerZoom.maxPan(display: display, viewport: viewport)
            let canPan = limit.width > 0.5 || limit.height > 0.5

            picture
                .frame(width: display.width, height: display.height)
                .offset(offset)
                .frame(width: viewport.width, height: viewport.height)
                .overlay {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { controller.togglePlayPause() }
                        // Alongside the click: a drag that moves cancels the click on its own.
                        .simultaneousGesture(panGesture(offset: offset, display: display, viewport: viewport),
                                             including: canPan ? .all : .subviews)
                        .pointerStyle(canPan && (dragStart != nil || isShiftDown)
                                      ? (dragStart != nil ? .grabActive : .grabIdle)
                                      : nil)
                }
        }
        .background(.black)
        .clipped()
        .onModifierKeysChanged(mask: .shift) { _, keys in
            isShiftDown = keys.contains(.shift)
        }
    }

    /// The video, plus the still frames that cover it at times. They all share one frame,
    /// so they stay lined up at every zoom.
    private var picture: some View {
        PlayerLayerView(player: controller.player)
            .overlay {
                // Still frame that covers version switches (Show Original), so there's no black flash.
                if let frame = controller.freezeFrame {
                    still(frame)
                }
            }
            .overlay {
                // Quick, smaller preview of the color while a color slider is dragged.
                if let proxy = controller.colorProxy {
                    still(proxy)
                }
            }
    }

    private func still(_ image: CGImage) -> some View {
        Image(decorative: image, scale: 1)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.black)
            .allowsHitTesting(false)
    }

    /// Shift-drag moves the picture with the pointer.
    private func panGesture(offset: CGSize, display: CGSize, viewport: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                if dragStart == nil {
                    let flags = NSApp.currentEvent?.modifierFlags ?? NSEvent.modifierFlags
                    guard flags.contains(.shift) else { return }
                    dragStart = offset
                }
                guard let dragStart else { return }
                let moved = ViewerZoom.clamp(
                    CGSize(width: dragStart.width + value.translation.width,
                           height: dragStart.height + value.translation.height),
                    display: display, viewport: viewport)
                pan = CGSize(width: moved.width / display.width, height: moved.height / display.height)
            }
            .onEnded { _ in dragStart = nil }
    }
}

/// Just the video picture, sized to its frame. Used instead of AVPlayerView here because the
/// zoomed picture can be many times bigger than the window, and a bare player layer
/// handles that cheaply (the screen compositor scales the video).
private struct PlayerLayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> PlayerLayerNSView {
        let view = PlayerLayerNSView()
        view.playerLayer.player = player
        return view
    }

    func updateNSView(_ view: PlayerLayerNSView, context: Context) {
        if view.playerLayer.player !== player {
            view.playerLayer.player = player
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: PlayerLayerNSView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions(by: CGSize(width: 320, height: 180))
    }
}

private final class PlayerLayerNSView: NSView {
    let playerLayer = AVPlayerLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        playerLayer.videoGravity = .resizeAspect
        playerLayer.backgroundColor = NSColor.black.cgColor
        layer = playerLayer
        wantsLayer = true
        // No natural size: SwiftUI decides it (see PlayerView).
        for orientation in [NSLayoutConstraint.Orientation.horizontal, .vertical] {
            setContentHuggingPriority(.init(1), for: orientation)
            setContentCompressionResistancePriority(.init(1), for: orientation)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}

// MARK: Zoom control

/// "Fit | 100% | Zoom ▾": a segmented control. The third segment opens a menu of other zooms
/// and then shows the chosen one.
struct ViewerZoomControl: NSViewRepresentable {
    @Binding var zoom: ViewerZoom

    private static let menuChoices: [ViewerZoom?] =
        [.fitHeight, .fitWidth, nil] + ViewerZoom.menuPercents.map { .percent($0) }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSSegmentedControl {
        let coordinator = context.coordinator
        let control = NSSegmentedControl(labels: ["Fit", "100%", "Zoom"], trackingMode: .selectOne,
                                         target: coordinator, action: #selector(Coordinator.segmentClicked(_:)))
        control.segmentStyle = .rounded
        control.controlSize = .small
        control.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        control.setWidth(40, forSegment: 0)
        control.setWidth(44, forSegment: 1)
        control.setWidth(84, forSegment: 2)
        control.setToolTip("Show the whole picture", forSegment: 0)
        control.setToolTip("Show the picture at full size, one video pixel per screen pixel. Shift-drag to move around.", forSegment: 1)
        control.setToolTip("More zoom sizes. Shift-drag to move around when the picture is cut off.", forSegment: 2)
        control.setContentHuggingPriority(.required, for: .horizontal)

        let menu = NSMenu()
        menu.delegate = coordinator
        menu.autoenablesItems = false
        for choice in Self.menuChoices {
            guard let choice else {
                menu.addItem(.separator())
                continue
            }
            let item = NSMenuItem(title: choice.menuTitle, action: #selector(Coordinator.choose(_:)), keyEquivalent: "")
            item.target = coordinator
            item.representedObject = choice.boxed
            menu.addItem(item)
        }
        control.setMenu(menu, forSegment: 2)
        control.setShowsMenuIndicator(true, forSegment: 2)
        coordinator.control = control
        coordinator.menu = menu
        return control
    }

    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.zoom = $zoom
        context.coordinator.sync()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSSegmentedControl, context: Context) -> CGSize? {
        nsView.intrinsicContentSize
    }

    @MainActor
    final class Coordinator: NSObject, NSMenuDelegate {
        var zoom: Binding<ViewerZoom>?
        weak var control: NSSegmentedControl?
        weak var menu: NSMenu?
        /// When the menu last closed, so a click that AppKit already answered with the menu
        /// doesn't open it a second time.
        private var menuClosedAt = Date.distantPast
        private var isMenuOpen = false

        /// Shows the current zoom in the control and checks it in the menu.
        func sync() {
            guard let control, let zoom = zoom?.wrappedValue else { return }
            let isCustom = zoom != .fit && zoom != .actual
            control.selectedSegment = zoom == .fit ? 0 : zoom == .actual ? 1 : 2
            control.setLabel(isCustom ? zoom.title : "Zoom", forSegment: 2)
            for item in menu?.items ?? [] {
                item.state = (item.representedObject as? ZoomBox)?.zoom == zoom ? .on : .off
            }
        }

        @objc func segmentClicked(_ control: NSSegmentedControl) {
            switch control.selectedSegment {
            case 0: zoom?.wrappedValue = .fit
            case 1: zoom?.wrappedValue = .actual
            default:
                // Depending on how it was clicked, AppKit may have shown the menu already.
                if !isMenuOpen, Date().timeIntervalSince(menuClosedAt) > 0.3, let menu {
                    let x = control.width(forSegment: 0) + control.width(forSegment: 1) + 4
                    menu.popUp(positioning: nil, at: NSPoint(x: x, y: control.isFlipped ? control.bounds.maxY + 4 : -4), in: control)
                }
            }
            sync()
        }

        @objc func choose(_ item: NSMenuItem) {
            guard let choice = (item.representedObject as? ZoomBox)?.zoom else { return }
            zoom?.wrappedValue = choice
            sync()
        }

        func menuWillOpen(_ menu: NSMenu) {
            isMenuOpen = true
        }

        func menuDidClose(_ menu: NSMenu) {
            isMenuOpen = false
            menuClosedAt = Date()
            // Closed without choosing: go back to showing the current zoom.
            DispatchQueue.main.async { [weak self] in self?.sync() }
        }
    }
}

/// A zoom that can ride along on a menu item.
private final class ZoomBox: NSObject {
    let zoom: ViewerZoom
    init(_ zoom: ViewerZoom) { self.zoom = zoom }
}

private extension ViewerZoom {
    var boxed: ZoomBox { ZoomBox(self) }
}
