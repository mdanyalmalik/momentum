import Foundation

/// A small, dependency-free Markdown block parser (CommonMark-ish): headings, paragraphs, bullet / numbered /
/// task lists (nested by indentation), fenced code, block quotes, rules and pipe tables. Inline formatting
/// (bold, italic, code, links, strikethrough) is left in the text for the renderer.
public enum MarkdownBlock: Hashable, Sendable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case listItem(indent: Int, marker: ListMarker, text: String)
    case code(language: String, text: String)
    case quote(String)
    case rule
    case table(header: [String], rows: [[String]])

    public enum ListMarker: Hashable, Sendable {
        case bullet
        case number(Int)
        case task(done: Bool)
    }
}

public enum MarkdownParser {
    public static func parse(_ source: String) -> [MarkdownBlock] {
        let lines = source.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var quote: [String] = []
        var i = 0

        func flush() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: "\n"))); paragraph = [] }
            if !quote.isEmpty { blocks.append(.quote(quote.joined(separator: "\n"))); quote = [] }
        }

        while i < lines.count {
            let raw = lines[i]
            let line = raw.trimmingCharacters(in: .whitespaces)

            // Fenced code.
            if line.hasPrefix("```") || line.hasPrefix("~~~") {
                flush()
                let fence = String(line.prefix(3))
                let lang = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var body: [String] = []
                i += 1
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                    body.append(lines[i]); i += 1
                }
                blocks.append(.code(language: lang, text: body.joined(separator: "\n")))
                i += 1
                continue
            }

            if line.isEmpty { flush(); i += 1; continue }

            // Heading.
            if line.hasPrefix("#") {
                let level = line.prefix(while: { $0 == "#" }).count
                let rest = line.dropFirst(level)
                if level <= 6, rest.isEmpty || rest.hasPrefix(" ") {
                    flush()
                    blocks.append(.heading(level: level, text: rest.trimmingCharacters(in: .whitespaces)
                        .trimmingCharacters(in: CharacterSet(charactersIn: "#")).trimmingCharacters(in: .whitespaces)))
                    i += 1
                    continue
                }
            }

            // Rule.
            let compact = line.replacingOccurrences(of: " ", with: "")
            if compact.count >= 3, Set(compact).count == 1, let c = compact.first, "-*_".contains(c) {
                flush(); blocks.append(.rule); i += 1; continue
            }

            // Quote.
            if line.hasPrefix(">") {
                if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: "\n"))); paragraph = [] }
                quote.append(String(line.dropFirst()).trimmingCharacters(in: .whitespaces))
                i += 1
                continue
            }

            // Table: a pipe row followed by a separator row.
            if line.hasPrefix("|"), i + 1 < lines.count, isTableSeparator(lines[i + 1]) {
                flush()
                let header = cells(line)
                var rows: [[String]] = []
                i += 2
                while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("|") {
                    rows.append(cells(lines[i])); i += 1
                }
                blocks.append(.table(header: header, rows: rows))
                continue
            }

            // List item.
            if let item = listItem(raw) {
                flush()
                blocks.append(item)
                i += 1
                continue
            }

            if !quote.isEmpty { flush() }
            paragraph.append(line)
            i += 1
        }
        flush()
        return blocks
    }

    static func listItem(_ raw: String) -> MarkdownBlock? {
        let indentWidth = raw.prefix(while: { $0 == " " || $0 == "\t" }).reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
        let line = raw.trimmingCharacters(in: .whitespaces)
        let indent = indentWidth / 2
        for b in ["- ", "* ", "+ "] where line.hasPrefix(b) {
            let rest = String(line.dropFirst(2))
            for (box, done) in [("[ ] ", false), ("[x] ", true), ("[X] ", true)] where rest.hasPrefix(box) {
                return .listItem(indent: indent, marker: .task(done: done), text: String(rest.dropFirst(4)))
            }
            return .listItem(indent: indent, marker: .bullet, text: rest)
        }
        let digits = line.prefix(while: \.isNumber)
        if !digits.isEmpty, digits.count <= 9 {
            let rest = line.dropFirst(digits.count)
            if rest.hasPrefix(". ") || rest.hasPrefix(") ") {
                return .listItem(indent: indent, marker: .number(Int(digits) ?? 1), text: String(rest.dropFirst(2)))
            }
        }
        return nil
    }

    static func isTableSeparator(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard t.contains("-"), t.contains("|") else { return false }
        return t.allSatisfy { "|-: ".contains($0) }
    }

    static func cells(_ s: String) -> [String] {
        var t = s.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("|") { t.removeFirst() }
        if t.hasSuffix("|") { t.removeLast() }
        return t.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }
}
