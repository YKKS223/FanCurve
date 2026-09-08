import SwiftUI

/// Segmented control with a highlight that slides between segments.
///
/// Replaces `Picker(.segmented)` throughout the app. That one is drawn by AppKit's
/// `NSSegmentedControl`, so SwiftUI's `.animation` never reaches its highlight and the
/// selection simply jumps — with the daemon round trip down to about 30 ms there was nothing
/// left to perceive at all.
///
/// Timing is chosen for perception, not for how long the underlying work takes:
///
///   * under ~100 ms reads as instantaneous — the eye registers a jump, not movement
///   * 200–300 ms is where a state change can be followed comfortably
///   * beyond ~400 ms it starts to feel like waiting
///
/// A spring is used rather than a fixed curve because its deceleration matches how the eye
/// expects something to settle, damped hard enough not to bounce — a bounce would imply an
/// overshoot that did not happen. It settles and stops: nothing here repeats, and nothing is
/// driven by a value that changes faster than the animation finishes.
struct SegmentedSelector<Value: Hashable>: View {
    let items: [Value]
    let selection: Value
    var label: (Value) -> String
    var systemImage: ((Value) -> String)? = nil
    var equalWidths: Bool = true
    let onSelect: (Value) -> Void

    @Namespace private var highlight
    @State private var hovering: Value?

    var body: some View {
        HStack(spacing: 2) {
            ForEach(items, id: \.self) { item in
                segment(item)
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.secondary.opacity(0.16))
        )
        .animation(.spring(response: 0.28, dampingFraction: 0.86), value: selection)
    }

    private func segment(_ item: Value) -> some View {
        let isSelected = item == selection
        return HStack(spacing: 5) {
            if let systemImage {
                Image(systemName: systemImage(item)).font(.system(size: 11))
            }
            Text(label(item))
                .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
        }
        .foregroundStyle(isSelected ? Color.white : Color.primary)
        .lineLimit(1)
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .frame(maxWidth: equalWidths ? .infinity : nil)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.accentColor)
                    .matchedGeometryEffect(id: "selection", in: highlight)
            } else if hovering == item {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(0.07))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { if !isSelected { onSelect(item) } }
        .onHover { hovering = $0 ? item : (hovering == item ? nil : hovering) }
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityLabel(label(item))
    }
}
