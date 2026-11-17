import MomentumCore
import SwiftUI

/// Renders Markdown with native SwiftUI: block structure from `MarkdownParser`, inline formatting
/// (bold, italic, `code`, links, ~~strike~~) via AttributedString.
struct MarkdownView: View {
    let source: String
    /// Ticking a task box in the preview edits the source.
    var onToggleTask: ((Int) -> Void)?

    var body: some View {
        let blocks = MarkdownParser.parse(source)
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                view(for: block, taskIndex: taskIndex(before: index, in: blocks))
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func taskIndex(before index: Int, in blocks: [MarkdownBlock]) -> Int {
        blocks.prefix(index).filter { if case .listItem(_, .task, _) = $0 { return true } else { return false } }.count
    }

    @ViewBuilder
    private func view(for block: MarkdownBlock, taskIndex: Int) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(inline(text))
                .font(level == 1 ? .title.bold() : level == 2 ? .title2.bold() : level == 3 ? .title3.weight(.semibold) : .headline)
                .padding(.top, level <= 2 ? 8 : 4)
        case .paragraph(let text):
            Text(inline(text)).fixedSize(horizontal: false, vertical: true)
        case .listItem(let indent, let marker, let text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                switch marker {
                case .bullet: Text("•").foregroundStyle(.secondary)
                case .number(let n): Text("\(n).").monospacedDigit().foregroundStyle(.secondary)
                case .task(let done):
                    Button { onToggleTask?(taskIndex) } label: {
                        Image(systemName: done ? "checkmark.square.fill" : "square").foregroundStyle(done ? Color.accentColor : .secondary)
                    }
                    .buttonStyle(.plain)
                }
                Text(inline(text))
                    .strikethrough({ if case .task(true) = marker { return true } else { return false } }())
                    .foregroundStyle({ if case .task(true) = marker { return Color.secondary } else { return Color.primary } }())
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, CGFloat(indent) * 18)
        case .code(_, let text):
            ScrollView(.horizontal) {
                Text(text).font(.system(.callout, design: .monospaced)).padding(10)
            }
            .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
        case .quote(let text):
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 2).fill(Color.secondary.opacity(0.4)).frame(width: 3)
                Text(inline(text)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        case .rule:
            Divider().padding(.vertical, 4)
        case .table(let header, let rows):
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                GridRow { ForEach(Array(header.enumerated()), id: \.offset) { Text(inline($0.element)).bold() } }
                Divider()
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    GridRow { ForEach(Array(row.enumerated()), id: \.offset) { Text(inline($0.element)) } }
                }
            }
            .padding(10)
            .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func inline(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }
}
