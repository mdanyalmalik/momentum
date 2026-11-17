import MomentumCore
import SwiftUI

extension BucketKind {
    var color: Color {
        switch self {
        case .anchor: Color(red: 0.93, green: 0.55, blue: 0.20)
        case .mainWork: Color(red: 0.36, green: 0.42, blue: 0.86)
        case .hobby: Color(red: 0.22, green: 0.66, blue: 0.52)
        case .errand: Color(red: 0.55, green: 0.52, blue: 0.62)
        }
    }

    var icon: String {
        switch self {
        case .anchor: "sunrise"
        case .mainWork: "hammer"
        case .hobby: "leaf"
        case .errand: "checklist"
        }
    }
}

/// Lays children out left to right, wrapping onto new lines (for tags on narrow cards).
struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        return CGSize(width: rows.map(\.width).max() ?? 0, height: rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(rows.count - 1, 0)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for i in row.items {
                let size = subviews[i].sizeThatFits(.unspecified)
                subviews[i].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [(items: [Int], width: CGFloat, height: CGFloat)] {
        var rows: [(items: [Int], width: CGFloat, height: CGFloat)] = []
        for (i, v) in subviews.enumerated() {
            let s = v.sizeThatFits(.unspecified)
            if let last = rows.last, last.width + spacing + s.width <= width {
                rows[rows.count - 1].items.append(i)
                rows[rows.count - 1].width += spacing + s.width
                rows[rows.count - 1].height = max(last.height, s.height)
            } else {
                rows.append(([i], s.width, s.height))
            }
        }
        return rows
    }
}

extension PlannedBlock {
    var tint: Color { bucket?.color ?? .secondary }
    var timeRange: String {
        "\(start.formatted(date: .omitted, time: .shortened))–\(end.formatted(date: .omitted, time: .shortened))"
    }
}

enum Fmt {
    static func minutes(_ m: Int) -> String {
        if m < 60 { return "\(m) min" }
        let h = m / 60, r = m % 60
        return r == 0 ? "\(h) h" : "\(h) h \(r) min"
    }

    static func short(_ m: Int) -> String {
        if m < 60 { return "\(m)m" }
        let h = m / 60, r = m % 60
        return r == 0 ? "\(h)h" : "\(h)h \(r)m"
    }

    static func clock(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds.rounded()))
        if s >= 3600 { return String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) }
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// Small rounded capsule label.
struct Tag: View {
    let text: String
    var icon: String? = nil
    var color: Color = .secondary

    var body: some View {
        HStack(spacing: 3) {
            if let icon { Image(systemName: icon) }
            Text(text)
        }
        .font(.caption2.weight(.medium))
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(color.opacity(0.14), in: Capsule())
        .foregroundStyle(color)
    }
}

struct PriorityDots: View {
    let priority: Int
    var color: Color = .accentColor

    var body: some View {
        HStack(spacing: 2) {
            ForEach(1...5, id: \.self) { i in
                Circle()
                    .fill(i <= priority ? color : color.opacity(0.18))
                    .frame(width: 5, height: 5)
            }
        }
        .accessibilityLabel("Priority \(priority) of 5")
    }
}

/// Weekly progress bar that never looks like a failure: it just fills up.
struct TargetProgress: View {
    let done: Int
    let planned: Int
    let target: Int
    let color: Color

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let t = Double(max(target, 1))
            ZStack(alignment: .leading) {
                Capsule().fill(color.opacity(0.12))
                Capsule().fill(color.opacity(0.35))
                    .frame(width: w * min(Double(done + planned) / t, 1))
                Capsule().fill(color)
                    .frame(width: w * min(Double(done) / t, 1))
            }
        }
        .frame(height: 5)
        .accessibilityLabel("\(done) of \(target) this week, \(planned) more planned")
    }
}

struct SectionCard<Content: View>: View {
    var padding: CGFloat = 16
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.separator.opacity(0.5)))
    }
}
