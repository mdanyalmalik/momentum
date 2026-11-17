import MomentumCore
import SwiftUI

/// A duration you can type ("45", "1h30", "1.5h", "1:30") or nudge with arrows. Reformats on commit,
/// reverts if it can't read what was typed.
struct DurationField: View {
    let title: String
    @Binding var minutes: Int
    var bareUnit: DurationParser.Unit = .minutes
    var range: ClosedRange<Int> = 1...1440
    var step: Int = 5
    var help: String?
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 4) {
                TextField(title, text: $text, prompt: Text(bareUnit == .hours ? "e.g. 6h" : "e.g. 45 min"))
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 96)
                    .focused($focused)
                    .onSubmit(commit)
                    .onChange(of: focused) { _, isFocused in if !isFocused { commit() } }
                Stepper(title, value: Binding(get: { minutes }, set: { minutes = clamp($0); text = DurationParser.format(minutes) }),
                        in: range, step: step)
                    .labelsHidden()
            }
        }
        .help(help ?? "Type a duration like 45, 1h30 or 1.5h")
        .onAppear { text = DurationParser.format(minutes) }
        .onChange(of: minutes) { _, m in if !focused { text = DurationParser.format(m) } }
    }

    private func clamp(_ m: Int) -> Int { min(max(m, range.lowerBound), range.upperBound) }

    private func commit() {
        if let m = DurationParser.minutes(from: text, bareUnit: bareUnit) { minutes = clamp(m) }
        text = DurationParser.format(minutes)
    }
}

/// A whole number you can type or nudge, with an optional unit ("× a week", "days").
struct NumberField: View {
    let title: String
    @Binding var value: Int
    var range: ClosedRange<Int> = 0...100
    var unit: String = ""
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 4) {
                TextField(title, text: $text)
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 56)
                    .focused($focused)
                    .onSubmit(commit)
                    .onChange(of: focused) { _, isFocused in if !isFocused { commit() } }
                if !unit.isEmpty { Text(unit).foregroundStyle(.secondary) }
                Stepper(title, value: Binding(get: { value }, set: { value = min(max($0, range.lowerBound), range.upperBound); text = "\(value)" }),
                        in: range)
                    .labelsHidden()
            }
        }
        .onAppear { text = "\(value)" }
        .onChange(of: value) { _, v in if !focused { text = "\(v)" } }
    }

    private func commit() {
        let digits = text.trimmingCharacters(in: .whitespaces).filter { $0.isNumber || $0 == "-" }
        if let v = Int(digits) { value = min(max(v, range.lowerBound), range.upperBound) }
        text = "\(value)"
    }
}
