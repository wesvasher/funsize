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
    /// Goes back to Fit (the navigator's close button).
    var zoomToFit: () -> Void = {}
    /// Told the part of the picture on screen (0…1 fractions) and its size there in pixels.
    var reportView: (_ fraction: CGRect, _ pixels: CGSize) -> Void = { _, _ in }

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
                .overlay(alignment: .bottomTrailing) {
                    // Zoomed in: a map of the whole picture, with the part in view outlined.
                    if canPan {
                        ViewerNavigator(player: controller.player, offset: offset, display: display, viewport: viewport,
                                        close: zoomToFit) { newOffset in
                            pan = CGSize(width: newOffset.width / display.width, height: newOffset.height / display.height)
                        }
                        .padding(12)
                        .transition(.opacity)
                    }
                }
                .animation(.easeOut(duration: 0.15), value: canPan)
                .onChange(of: [offset.width, offset.height, display.width, display.height, viewport.width, viewport.height, displayScale],
                          initial: true) {
                    let fraction = ViewerZoom.visibleFraction(offset: offset, display: display, viewport: viewport)
                    reportView(fraction, CGSize(width: fraction.width * display.width * displayScale,
                                                height: fraction.height * display.height * displayScale))
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

/// A small, live copy of the whole picture with the part in view outlined.
/// Drag the box to look around; click anywhere in the map to jump there.
private struct ViewerNavigator: View {
    let player: AVPlayer
    /// How far the picture has moved from centered, in points.
    let offset: CGSize
    let display: CGSize
    let viewport: CGSize
    let close: () -> Void
    let move: (CGSize) -> Void

    /// Where the pointer grabbed the box, from the box's middle, so it doesn't jump.
    @State private var grab: CGSize?

    private static let maxSize = CGSize(width: 160, height: 110)

    var body: some View {
        let size = mapSize
        let visible = ViewerZoom.visibleRect(offset: offset, display: display, viewport: viewport, navigator: size)

        ZStack(alignment: .topLeading) {
            // The same player again: shows the current frame while playing and scrubbing.
            PlayerLayerView(player: player)

            Rectangle()
                .fill(Color.accentColor.opacity(0.18))
                .strokeBorder(Color.accentColor, lineWidth: 2)
                .frame(width: visible.width, height: visible.height)
                .offset(x: visible.minX, y: visible.minY)
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .padding(6)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(0.15))
        }
        .contentShape(Rectangle())
        .gesture(dragGesture(size: size, visible: visible))
        .pointerStyle(grab != nil ? .grabActive : .grabIdle)
        .help("Drag the box to move around the picture")
        .accessibilityElement()
        .accessibilityLabel("Zoom navigator")
        .overlay(alignment: .topTrailing) {
            // Outside the map's gesture, so a click here doesn't move the view.
            // The whole circle is the button, not just the X: it's drawn inside the label.
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 15, height: 15)
                    .background(.black.opacity(0.8), in: Circle())
                    .overlay { Circle().strokeBorder(.white.opacity(0.35)) }
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Zoom to Fit")
            .offset(x: 5, y: -5)
            .help("Zoom to fit")
        }
    }

    /// The whole picture's shape, as big as fits in `maxSize`.
    private var mapSize: CGSize {
        guard display.width > 0, display.height > 0 else { return Self.maxSize }
        let scale = min(Self.maxSize.width / display.width, Self.maxSize.height / display.height)
        return CGSize(width: (display.width * scale).rounded(), height: (display.height * scale).rounded())
    }

    private func dragGesture(size: CGSize, visible: CGRect) -> some Gesture {
        // The map sits inside 6 points of padding.
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                let start = CGPoint(x: value.startLocation.x - 6, y: value.startLocation.y - 6)
                if grab == nil {
                    // Grabbing the box keeps its spot under the pointer; elsewhere, the box centers there.
                    grab = visible.contains(start)
                        ? CGSize(width: start.x - visible.midX, height: start.y - visible.midY)
                        : .zero
                }
                let grab = grab ?? .zero
                let center = CGPoint(x: start.x + value.translation.width - grab.width,
                                     y: start.y + value.translation.height - grab.height)
                move(ViewerZoom.offset(navigatorCenter: center, navigator: size, display: display, viewport: viewport))
            }
            .onEnded { _ in grab = nil }
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

    // Never takes clicks. Zoomed in, this view is bigger than the viewer, and SwiftUI's clipping
    // only hides the overflow: without this it would take clicks meant for the controls around
    // the viewer. Clicks on the picture go to the SwiftUI layer above it.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
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
