import SwiftUI

enum MoniMotion {
    static let press = Animation.easeOut(duration: 0.12)
    static let data = Animation.easeOut(duration: 0.24)
    static let standard = Animation.spring(response: 0.32, dampingFraction: 0.86)
    static let navigation = Animation.spring(response: 0.38, dampingFraction: 0.9)
    static let dashboardReflow = Animation.interactiveSpring(
        response: 0.5,
        dampingFraction: 0.92,
        blendDuration: 0.18
    )
    static let dashboardSnap = Animation.spring(
        response: 0.42,
        dampingFraction: 0.95,
        blendDuration: 0.12
    )

    static let pageTransition = AnyTransition.opacity.combined(
        with: .scale(scale: 0.985, anchor: .top)
    )
    static let itemTransition = AnyTransition.opacity.combined(
        with: .scale(scale: 0.96, anchor: .center)
    )
}

struct MoniPressButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var scale = 0.97

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(reduceMotion || !configuration.isPressed ? 1 : scale)
            .opacity(configuration.isPressed ? 0.78 : 1)
            .animation(reduceMotion ? nil : MoniMotion.press, value: configuration.isPressed)
            .moniPointingHand()
    }
}

private struct MoniNumericTransition<Value: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let value: Value

    @ViewBuilder
    func body(content: Content) -> some View {
        if reduceMotion {
            content
        } else {
            content
                .contentTransition(.numericText())
                .animation(MoniMotion.data, value: value)
        }
    }
}

private struct MoniValueAnimation<Value: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let value: Value
    let animation: Animation

    func body(content: Content) -> some View {
        content.animation(reduceMotion ? nil : animation, value: value)
    }
}

extension View {
    /// `pointerStyle` is scoped to the view, so it cannot leave the cursor stack
    /// unbalanced the way a manual `NSCursor.push()`/`pop()` pair can when a view
    /// disappears while hovered.
    func moniPointingHand() -> some View {
        pointerStyle(.link)
    }

    func moniNumericTransition<Value: Equatable>(_ value: Value) -> some View {
        modifier(MoniNumericTransition(value: value))
    }

    func moniAnimation<Value: Equatable>(
        _ animation: Animation = MoniMotion.standard,
        value: Value
    ) -> some View {
        modifier(MoniValueAnimation(value: value, animation: animation))
    }
}
