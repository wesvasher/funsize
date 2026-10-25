import CoreGraphics
import Testing
@testable import SwiftCut

struct ViewerZoomTests {
    let uhd = CGSize(width: 3840, height: 2160)
    let viewport = CGSize(width: 960, height: 720)

    @Test func fitShowsTheWholePicture() {
        let size = ViewerZoom.fit.displaySize(picture: uhd, viewport: viewport, pixelsPerPoint: 2)
        #expect(size == CGSize(width: 960, height: 540))
        #expect(ViewerZoom.maxPan(display: size, viewport: viewport) == .zero)
    }

    @Test func actualSizeIsOneVideoPixelPerScreenPixel() {
        #expect(ViewerZoom.actual.displaySize(picture: uhd, viewport: viewport, pixelsPerPoint: 2)
                == CGSize(width: 1920, height: 1080))
        #expect(ViewerZoom.actual.displaySize(picture: uhd, viewport: viewport, pixelsPerPoint: 1) == uhd)
    }

    @Test func percentagesScaleFromActualSize() {
        #expect(ViewerZoom.percent(2).displaySize(picture: uhd, viewport: viewport, pixelsPerPoint: 2)
                == CGSize(width: 3840, height: 2160))
        #expect(ViewerZoom.percent(0.25).displaySize(picture: uhd, viewport: viewport, pixelsPerPoint: 2)
                == CGSize(width: 480, height: 270))
    }

    @Test func fitHeightAndWidthFillOneDirection() {
        let height = ViewerZoom.fitHeight.displaySize(picture: uhd, viewport: viewport, pixelsPerPoint: 2)
        #expect(height.height == 720)
        #expect(height.width == 1280)
        let width = ViewerZoom.fitWidth.displaySize(picture: uhd, viewport: viewport, pixelsPerPoint: 2)
        #expect(width.width == 960)
    }

    @Test func panStopsAtThePictureEdges() {
        let display = CGSize(width: 1920, height: 1080)
        // 480 points spare on each side, and 180 above and below.
        #expect(ViewerZoom.maxPan(display: display, viewport: viewport) == CGSize(width: 480, height: 180))
        #expect(ViewerZoom.clamp(CGSize(width: 1000, height: -1000), display: display, viewport: viewport)
                == CGSize(width: 480, height: -180))
        // A picture smaller than the viewer stays centered.
        #expect(ViewerZoom.clamp(CGSize(width: 50, height: 50), display: CGSize(width: 480, height: 270), viewport: viewport)
                == .zero)
    }

    @Test func namesForTheControlAndMenu() {
        #expect(ViewerZoom.percent(2).title == "200%")
        #expect(ViewerZoom.percent(2).menuTitle == "200% (2×)")
        #expect(ViewerZoom.percent(0.25).menuTitle == "25% (¼×)")
        #expect(ViewerZoom.fitHeight.menuTitle == "Fit Vertically")
    }
}
