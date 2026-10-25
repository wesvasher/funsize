import SwiftUI

/// Side-by-side tiles for choosing one option, each with an icon and a
/// label. The selected tile gets an accent border and a check in its corner;
/// switching animates the border and gives the new tile's icon and label a
/// little bounce. Same design as CardStock's appearance tiles, minus its fixed-size
/// text, which blanks the Settings window on macOS 27.
struct ChoiceCards<Value: Hashable>: View {
    struct Option {
        var value: Value
        var title: String
        var systemImage: String
        /// Hover text.
        var help: String = ""
    }

    @Binding var selection: Value
    let options: [Option]

    var body: some View {
        HStack(spacing: 10) {
            ForEach(options.indices, id: \.self) { i in
                let option = options[i]
                ChoiceCard(title: option.title, systemImage: option.systemImage, help: option.help,
                           isSelected: selection == option.value) {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                        selection = option.value
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }
}

struct ChoiceCard: View {
    let title: String
    let systemImage: String
    let help: String
    let isSelected: Bool
    let action: () -> Void

    /// Bumped each time this tile becomes selected, to replay the bounce.
    @State private var bounce = 0

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 22, weight: .medium))
                    .frame(height: 26)
                    .symbolEffect(.bounce, value: bounce)
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                Text(title)
                    .font(.callout.weight(isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }
            .keyframeAnimator(initialValue: 1.0, trigger: bounce) { content, scale in
                content.scaleEffect(scale)
            } keyframes: { _ in
                SpringKeyframe(1.12, duration: 0.14)
                SpringKeyframe(0.96, duration: 0.12)
                SpringKeyframe(1.0, duration: 0.2)
            }
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.vertical, 14)
            // Only the fill and border animate the selection, never the
            // card's position.
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isSelected ? Color.accentColor.opacity(0.08) : Color(nsColor: .controlBackgroundColor))
                    .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isSelected)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(isSelected ? Color.accentColor : Color(nsColor: .separatorColor),
                                  lineWidth: isSelected ? 2 : 1)
                    .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isSelected)
            )
            .overlay(alignment: .topTrailing) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 14))
                    .foregroundStyle(isSelected ? Color.accentColor : Color(nsColor: .tertiaryLabelColor))
                    .contentTransition(.symbolEffect(.replace))
                    .padding(6)
            }
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .onChange(of: isSelected) { _, nowSelected in
            if nowSelected { bounce += 1 }
        }
    }
}
