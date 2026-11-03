import SwiftUI

extension View {
    /// What VoiceOver finds in a row that steps a value: one adjustable element, named `title`
    /// alone and valued at `valueText`, that a swipe up or down moves a step. The row on screen
    /// stays as it is drawn.
    ///
    /// A Stepper reads everything in its label into the name of both its buttons, and adds an
    /// `.accessibilityLabel` to that name rather than replacing it, so a Stepper that shows its
    /// value read it twice — 「字重、400, 增量」 and then 400 as the value — and one whose value
    /// differs from its binding read the binding: 「查看到第 3 章」 valued at 2. A labels-hidden
    /// Stepper beside its own text names its buttons nothing but 增量 and 減量.
    func accessibilityStepper<Value: Strideable>(
        _ title: String,
        value: Binding<Value>,
        in bounds: ClosedRange<Value>,
        step: Value.Stride = 1,
        valueText: String,
        onEditingChanged: @escaping (Bool) -> Void = { _ in }
    ) -> some View {
        accessibilityRepresentation {
            Stepper(title, value: value, in: bounds, step: step, onEditingChanged: onEditingChanged)
                .accessibilityValue(valueText)
        }
    }

    /// The same for a row that moves its value itself, with a rounding or a clamp a plain step
    /// would skip.
    func accessibilityStepper(
        _ title: String,
        valueText: String,
        onIncrement: @escaping () -> Void,
        onDecrement: @escaping () -> Void
    ) -> some View {
        accessibilityRepresentation {
            Stepper(title, onIncrement: onIncrement, onDecrement: onDecrement)
                .accessibilityValue(valueText)
        }
    }
}
