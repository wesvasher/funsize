import AppKit
import SwiftUI

// Building blocks shared by the clip and timeline inspectors.

/// An inspector: rounded sections that scroll, over a bar of buttons that stays put.
struct InspectorPanel<Sections: View, Footer: View>: View {
    @ViewBuilder let sections: () -> Sections
    @ViewBuilder let footer: () -> Footer
    /// How far the sections' area runs under the scroll bar.
    @State private var scrollBarOverhang: CGFloat = 0

    /// Space between the sections and the panel's sides.
    static var sidePadding: CGFloat { 5 }
    /// Space between one section and the next.
    static var sectionSpacing: CGFloat { 5 }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: Self.sectionSpacing) {
                    sections()
                }
                .padding(.leading, Self.sidePadding)
                // The scroll bar always shows, but SwiftUI doesn't always narrow the content for it
                // (it runs underneath until it scrolls). Pad by however much is hidden, so the
                // sections always stop the same distance from the scroll bar.
                .padding(.trailing, max(0, Self.sidePadding + scrollBarOverhang))
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(ThinScrollers { scrollBarOverhang = $0 })
            }
            Divider()
            // Buttons below the sections (also keeps the scroll bar clear of the window's rounded corner).
            HStack(spacing: 8) {
                footer()
            }
            .padding(.horizontal, Self.sidePadding)
            .padding(.top, 8)
            .padding(.bottom, 10)
            .background(.bar)
        }
        .font(.subheadline)
        .controlSize(.small)
    }
}

/// A rounded card with a small uppercase heading over a two-column grid of rows.
/// Click the heading to collapse or expand it; the choice is remembered per section.
struct InspectorSection<Accessory: View, Content: View>: View {
    let title: String
    let accessory: Accessory
    let content: Content
    @AppStorage private var isCollapsed: Bool

    init(_ title: String, @ViewBuilder accessory: () -> Accessory, @ViewBuilder content: () -> Content) {
        self.title = title
        self.accessory = accessory()
        self.content = content()
        _isCollapsed = AppStorage(wrappedValue: false, "inspectorCollapsed.\(title)")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 4) {
                Button {
                    withAnimation(.snappy(duration: 0.2)) { isCollapsed.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .bold))
                            .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                            .frame(width: 9)
                        Text(title.uppercased())
                            .font(.caption.weight(.semibold))
                        Spacer(minLength: 4)
                    }
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(isCollapsed ? "Show \(title)" : "Hide \(title)")
                .accessibilityLabel(title)
                .accessibilityValue(isCollapsed ? "Collapsed" : "Expanded")

                if !isCollapsed {
                    accessory
                }
            }
            .padding(.horizontal, 10)
            if !isCollapsed {
                Divider()
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 4) {
                    content
                }
                .padding(10)
                .transition(.opacity)
            }
        }
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(.separator.opacity(0.6))
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

/// Gives the surrounding scroll view an always-visible scroller at the small size,
/// instead of the regular-width one.
struct ThinScrollers: NSViewRepresentable {
    /// Called with how far the content runs under the scroll bar (or, if negative, how far
    /// short of it it stops), so the view can pad to keep a fixed gap beside the scroll bar.
    var onOverhang: (CGFloat) -> Void = { _ in }

    func makeNSView(context: Context) -> NSView { Probe() }
    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? Probe)?.onOverhang = onOverhang
    }

    private final class Probe: NSView {
        private var observer: NSObjectProtocol?
        var onOverhang: (CGFloat) -> Void = { _ in }
        private var lastOverhang: CGFloat?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            apply()
            if observer == nil {
                // macOS resets the style when the system setting or mouse changes.
                observer = NotificationCenter.default.addObserver(
                    forName: NSScroller.preferredScrollerStyleDidChangeNotification, object: nil, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated {
                        DispatchQueue.main.async { self?.apply() }
                    }
                }
            }
        }

        override func layout() {
            super.layout()
            measure()
        }

        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            measure()
        }

        /// The content's right edge compared with the visible area's (which ends at the scroll bar).
        private func measure() {
            guard let clip = enclosingScrollView?.contentView else { return }
            let overhang = (convert(bounds, to: clip).maxX - clip.bounds.maxX).rounded()
            guard overhang != lastOverhang else { return }
            lastOverhang = overhang
            let report = onOverhang
            DispatchQueue.main.async { report(overhang) }
        }

        private func apply() {
            guard let scrollView = enclosingScrollView else { return }
            scrollView.scrollerStyle = .legacy
            scrollView.autohidesScrollers = false
            scrollView.verticalScroller?.controlSize = .small
            scrollView.horizontalScroller?.controlSize = .small
        }

        isolated deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }
    }
}

extension InspectorSection where Accessory == EmptyView {
    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.init(title, accessory: { EmptyView() }, content: content)
    }
}

/// Label column: right-aligned, secondary color, fixed width so values line up.
struct InspectorLabel: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .foregroundStyle(.secondary)
            .frame(width: 78, alignment: .trailing)
            .gridColumnAlignment(.trailing)
    }
}

/// One "Label   value" row. Shows "—" when the file doesn't include the value.
struct InspectorRow: View {
    let title: String
    let value: String?

    init(_ title: String, _ value: String?) {
        self.title = title
        self.value = value
    }

    var body: some View {
        GridRow {
            InspectorLabel(title)
            Text(value ?? "—")
                .foregroundStyle(value == nil ? .secondary : .primary)
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
