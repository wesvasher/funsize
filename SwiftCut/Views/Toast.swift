import SwiftUI

/// A short message that appears for a few seconds to say what just happened.
struct Toast: Identifiable, Equatable {
    let id = UUID()
    var systemImage: String
    var title: String
    var detail: String? = nil
    var isError = false
    /// An optional button, like "Show in Finder".
    var action: ToastAction? = nil

    static func == (a: Toast, b: Toast) -> Bool { a.id == b.id }
}

struct ToastAction {
    var title: String
    var perform: () -> Void
}

extension View {
    /// Shows `toast` at the top of this view, then hides it after a few seconds.
    func toast(_ toast: Binding<Toast?>) -> some View {
        overlay(alignment: .top) {
            ToastHost(toast: toast)
        }
    }
}

private struct ToastHost: View {
    @Binding var toast: Toast?

    var body: some View {
        ZStack {
            if let toast {
                ToastView(toast: toast) { self.toast = nil }
                    .id(toast.id)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .onTapGesture { self.toast = nil }
                    .task(id: toast.id) {
                        // Longer when there's something to read or click.
                        try? await Task.sleep(for: .seconds(toast.isError || toast.action != nil ? 6 : 3))
                        guard !Task.isCancelled, self.toast?.id == toast.id else { return }
                        self.toast = nil
                    }
            }
        }
        .padding(.top, 12)
        .padding(.horizontal, 16)
        .animation(.snappy(duration: 0.25), value: toast)
    }
}

private struct ToastView: View {
    let toast: Toast
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: toast.systemImage)
                .foregroundStyle(toast.isError ? AnyShapeStyle(.yellow) : AnyShapeStyle(.tint))
                .font(.body.weight(.semibold))
            VStack(alignment: .leading, spacing: 2) {
                Text(toast.title)
                    .font(.callout.weight(.semibold))
                if let detail = toast.detail {
                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let action = toast.action {
                    Button(action.title) {
                        action.perform()
                        dismiss()
                    }
                    .buttonStyle(.link)
                    .font(.callout.weight(.medium))
                    .padding(.top, 2)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: 420, alignment: .leading)
        // Nearly solid and always dark: it sits over video, which can be any color.
        .background(Color(white: 0.13).opacity(0.94), in: RoundedRectangle(cornerRadius: 12))
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.12)) }
        .environment(\.colorScheme, .dark)
        .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
        .accessibilityElement(children: .combine)
    }
}
