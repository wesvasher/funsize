import AppKit
import SwiftUI
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

/// Zoomed in, the picture is bigger than the viewer. It must not take clicks meant for
/// the controls around the viewer (the zoom control used to stop working after zooming in).
@MainActor
struct ZoomedViewerClickTests {
    @Test func zoomControlStillTakesClicksWhenZoomedIn() async throws {
        let dir = try TestVideo.tempDirectory()
        let url = try await TestVideo.make(in: dir, name: "big", seconds: 1, size: CGSize(width: 1920, height: 1080))
        let store = ProjectStore(exporter: ExportManager.test())
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1200, height: 760),
                              styleMask: [.titled, .resizable, .closable], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: ContentView().environment(store).environment(store.exporter))
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        store.importAndSelect([url])
        func settle() async throws {
            for _ in 0..<20 {
                try await Task.sleep(for: .milliseconds(50))
                window.contentView?.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
            }
        }
        func findControl(_ view: NSView) -> NSSegmentedControl? {
            if let control = view as? NSSegmentedControl, control.segmentCount == 3, control.label(forSegment: 0) == "Fit" {
                return control
            }
            return view.subviews.lazy.compactMap(findControl).first
        }
        try await settle()
        let content = try #require(window.contentView)
        let control = try #require(findControl(content))
        func viewUnderControl() -> NSView? {
            let point = control.convert(NSPoint(x: 10, y: control.bounds.midY), to: nil)
            return content.hitTest(content.superview!.convert(point, from: nil))
        }
        #expect(viewUnderControl() === control)

        let menu = try #require(control.menu(forSegment: 2))
        menu.performActionForItem(at: try #require(menu.items.firstIndex { $0.title.hasPrefix("400%") }))
        try await settle()
        #expect(control.label(forSegment: 2) == "400%")
        #expect(viewUnderControl() === control)
    }
}

struct ViewerNavigatorTests {
    let display = CGSize(width: 1920, height: 1080)
    let viewport = CGSize(width: 960, height: 540)
    let map = CGSize(width: 160, height: 90)

    @Test func centeredViewIsInTheMiddleOfTheMap() {
        let rect = ViewerZoom.visibleRect(offset: .zero, display: display, viewport: viewport, navigator: map)
        #expect(rect == CGRect(x: 40, y: 22.5, width: 80, height: 45))
    }

    @Test func movingThePictureRightShowsItsLeftSide() {
        // Moved all the way right: the left edge of the picture is in view.
        let rect = ViewerZoom.visibleRect(offset: CGSize(width: 480, height: 270), display: display, viewport: viewport, navigator: map)
        #expect(rect.origin == .zero)
    }

    @Test func boxPositionAndOffsetRoundTrip() {
        let offset = CGSize(width: -200, height: 100)
        let rect = ViewerZoom.visibleRect(offset: offset, display: display, viewport: viewport, navigator: map)
        let back = ViewerZoom.offset(navigatorCenter: CGPoint(x: rect.midX, y: rect.midY), navigator: map,
                                     display: display, viewport: viewport)
        #expect(abs(back.width - offset.width) < 0.001)
        #expect(abs(back.height - offset.height) < 0.001)
    }

    @Test func boxStopsAtTheMapEdges() {
        let offset = ViewerZoom.offset(navigatorCenter: CGPoint(x: 500, y: -500), navigator: map,
                                       display: display, viewport: viewport)
        #expect(offset == CGSize(width: -480, height: 270))
    }
}
