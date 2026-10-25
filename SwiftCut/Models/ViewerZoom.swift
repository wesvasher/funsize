import CoreGraphics

/// How big the viewer shows the picture.
nonisolated enum ViewerZoom: Hashable, Sendable {
    /// The whole picture, as big as fits.
    case fit
    /// The picture's full height fills the viewer (the sides may be cut off).
    case fitHeight
    /// The picture's full width fills the viewer (the top and bottom may be cut off).
    case fitWidth
    /// Video pixels per screen pixel: 1 is 100% (1:1), 2 is 200%, 0.5 is 50%.
    case percent(Double)

    static let actual = ViewerZoom.percent(1)

    /// The choices in the viewer's zoom menu, biggest first.
    static let menuPercents: [Double] = [8, 4, 2, 0.5, 0.25]

    /// Short name, for the zoom control.
    var title: String {
        switch self {
        case .fit: "Fit"
        case .fitHeight: "Fit Height"
        case .fitWidth: "Fit Width"
        case .percent(let amount): Self.percentText(amount)
        }
    }

    /// Longer name, for the zoom menu.
    var menuTitle: String {
        switch self {
        case .fit: "Fit"
        case .fitHeight: "Fit Vertically"
        case .fitWidth: "Fit Horizontally"
        case .percent(let amount):
            switch amount {
            case 1: "100% (1:1)"
            case 0.5: "50% (½×)"
            case 0.25: "25% (¼×)"
            default: amount >= 1 && amount == amount.rounded()
                ? "\(Self.percentText(amount)) (\(Int(amount))×)"
                : Self.percentText(amount)
            }
        }
    }

    private static func percentText(_ amount: Double) -> String {
        let value = amount * 100
        return value == value.rounded() ? "\(Int(value))%" : String(format: "%.1f%%", value)
    }

    /// Size of the picture on screen, in points.
    /// - Parameters:
    ///   - picture: the video's size in pixels.
    ///   - viewport: the viewer's size in points.
    ///   - pixelsPerPoint: the screen's scale (2 on Retina), so 100% is one video pixel per screen pixel.
    func displaySize(picture: CGSize, viewport: CGSize, pixelsPerPoint: CGFloat) -> CGSize {
        guard picture.width > 0, picture.height > 0 else { return viewport }
        let scale: CGFloat = switch self {
        case .fit: min(viewport.width / picture.width, viewport.height / picture.height)
        case .fitHeight: viewport.height / picture.height
        case .fitWidth: viewport.width / picture.width
        case .percent(let amount): CGFloat(amount) / max(pixelsPerPoint, 1)
        }
        return CGSize(width: picture.width * scale, height: picture.height * scale)
    }

    /// How far the picture can move from the center before an edge comes into view.
    /// Zero along a direction where the whole picture already shows.
    static func maxPan(display: CGSize, viewport: CGSize) -> CGSize {
        CGSize(width: max(0, (display.width - viewport.width) / 2),
               height: max(0, (display.height - viewport.height) / 2))
    }

    // MARK: Navigator

    /// The part of the picture in view, drawn inside a navigator of size `navigator` that
    /// stands for the whole picture.
    /// - Parameter offset: how far the picture has moved from centered, in points (already clamped).
    static func visibleRect(offset: CGSize, display: CGSize, viewport: CGSize, navigator: CGSize) -> CGRect {
        guard display.width > 0, display.height > 0 else { return CGRect(origin: .zero, size: navigator) }
        let width = navigator.width * min(1, viewport.width / display.width)
        let height = navigator.height * min(1, viewport.height / display.height)
        // Moving the picture right shows more of its left side.
        let centerX = navigator.width * (0.5 - offset.width / display.width)
        let centerY = navigator.height * (0.5 - offset.height / display.height)
        return CGRect(x: centerX - width / 2, y: centerY - height / 2, width: width, height: height)
    }

    /// The picture offset (points from centered, clamped) that puts the middle of the view
    /// at `center`, a point in the navigator.
    static func offset(navigatorCenter center: CGPoint, navigator: CGSize, display: CGSize, viewport: CGSize) -> CGSize {
        guard navigator.width > 0, navigator.height > 0 else { return .zero }
        let offset = CGSize(width: (0.5 - center.x / navigator.width) * display.width,
                            height: (0.5 - center.y / navigator.height) * display.height)
        return clamp(offset, display: display, viewport: viewport)
    }

    /// `offset` (points from centered) moved back inside the limits.
    static func clamp(_ offset: CGSize, display: CGSize, viewport: CGSize) -> CGSize {
        let limit = maxPan(display: display, viewport: viewport)
        return CGSize(width: min(max(offset.width, -limit.width), limit.width),
                      height: min(max(offset.height, -limit.height), limit.height))
    }
}
