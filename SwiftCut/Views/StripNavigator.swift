import SwiftUI

/// A small overview of a zoomed-in strip (the clip viewer's filmstrip or the timeline) with
/// the part in view outlined, like the video's zoom navigator. Drag the box to scroll; click
/// anywhere else in it to jump there.
struct StripNavigator<Overview: View>: View {
    /// The strip's full width, in its own points.
    let contentWidth: CGFloat
    /// The part of the strip on screen.
    let visible: ClosedRange<CGFloat>
    /// The playhead's place along the strip.
    var playheadX: CGFloat?
    /// The marked in-to-out range along the strip, if any.
    var marked: ClosedRange<CGFloat>?
    /// Scrolls the strip so its left edge is at this place.
    let scroll: (CGFloat) -> Void
    /// Zooms back out to fit (which also hides the navigator).
    let close: () -> Void
    /// The whole strip in miniature, drawn at the width it's given.
    @ViewBuilder let overview: (_ width: CGFloat) -> Overview

    /// Where the pointer grabbed the box, from the box's middle, so it doesn't jump.
    @State private var grab: CGFloat?

    static var height: CGFloat { 20 }

    var body: some View {
        HStack(spacing: 6) {
            // Takes the space it's offered, whatever it draws.
            GeometryReader { geometry in
                map(width: geometry.size.width)
            }
            .frame(height: Self.height)

            Button("Zoom to Fit", systemImage: "arrow.right.and.line.vertical.and.arrow.left", action: close)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Zoom out to fit")
        }
    }

    private func map(width: CGFloat) -> some View {
        let scale = width / max(1, contentWidth)
        let box = boxRange(scale: scale, width: width)
        let height = Self.height

        return ZStack(alignment: .topLeading) {
            overview(width)
                .frame(width: width, height: height)

            if let marked {
                let inX = marked.lowerBound * scale, outX = marked.upperBound * scale
                Rectangle().fill(.black.opacity(0.5))
                    .frame(width: max(0, inX), height: height)
                Rectangle().fill(.black.opacity(0.5))
                    .frame(width: max(0, width - outX), height: height)
                    .offset(x: min(outX, width))
                RoundedRectangle(cornerRadius: 2)
                    .strokeBorder(Color.yellow.opacity(0.45), lineWidth: 1.5)
                    .frame(width: max(3, outX - inX), height: height)
                    .offset(x: min(inX, width - 3))
            }

            if let playheadX {
                Rectangle().fill(.white)
                    .frame(width: 1.5, height: height)
                    .offset(x: min(max(0, playheadX * scale - 0.75), width - 1.5))
            }

            Rectangle()
                .fill(Color.accentColor.opacity(0.18))
                .strokeBorder(Color.accentColor, lineWidth: 2)
                .frame(width: box.upperBound - box.lowerBound, height: height)
                .offset(x: box.lowerBound)
        }
        .frame(width: width, height: height, alignment: .topLeading)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay {
            RoundedRectangle(cornerRadius: 4).strokeBorder(.primary.opacity(0.15))
        }
        .contentShape(Rectangle())
        .gesture(drag(scale: scale, box: box))
        .pointerStyle(grab != nil ? .grabActive : .grabIdle)
        .help("Drag the box to move along the strip")
        .accessibilityElement()
        .accessibilityLabel("Zoom navigator")
    }

    /// The outlined box, at least a few points wide so it can be grabbed.
    private func boxRange(scale: CGFloat, width: CGFloat) -> ClosedRange<CGFloat> {
        let minimum: CGFloat = 6
        let boxWidth = min(width, max(minimum, (visible.upperBound - visible.lowerBound) * scale))
        let start = min(max(0, visible.lowerBound * scale), max(0, width - boxWidth))
        return start...(start + boxWidth)
    }

    private func drag(scale: CGFloat, box: ClosedRange<CGFloat>) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                let start = value.startLocation.x
                if grab == nil {
                    // Grabbing the box keeps its spot under the pointer; elsewhere, the box centers there.
                    grab = box.contains(start) ? start - (box.lowerBound + box.upperBound) / 2 : 0
                }
                guard scale > 0 else { return }
                let center = (start + value.translation.width - (grab ?? 0)) / scale
                let span = visible.upperBound - visible.lowerBound
                scroll(min(max(0, center - span / 2), max(0, contentWidth - span)))
            }
            .onEnded { _ in grab = nil }
    }
}
