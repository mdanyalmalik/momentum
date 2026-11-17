import Foundation

/// Parses what people type into a duration field: "45", "45m", "45 min", "1.5h", "1h30", "1h 30m", "1:30", "2 hours".
/// A bare number uses `bareUnit`. Returns minutes, or nil if it can't be read.
public enum DurationParser {
    public enum Unit: Sendable { case minutes, hours }

    public static func minutes(from text: String, bareUnit: Unit = .minutes) -> Int? {
        let s = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: ".")
        guard !s.isEmpty else { return nil }

        // "1:30"
        if s.contains(":") {
            let parts = s.split(separator: ":").map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]), h >= 0, (0..<60).contains(m) else { return nil }
            return h * 60 + m
        }

        // Bare number.
        if let n = Double(s) {
            guard n >= 0 else { return nil }
            return Int((bareUnit == .hours ? n * 60 : n).rounded())
        }

        // Number + unit tokens: "1h30", "1 h 30 m", "1.5 hours", "90min".
        var total = 0.0
        var number = ""
        var sawUnit = false
        var lastWasHours = false
        var chars = Array(s)
        chars.append(" ")
        var i = 0
        func flush(_ unit: Unit?) -> Bool {
            guard !number.isEmpty else { return unit == nil }
            guard let n = Double(number) else { return false }
            switch unit {
            case .hours: total += n * 60; lastWasHours = true
            case .minutes: total += n; lastWasHours = false
            case nil: total += lastWasHours ? n : (bareUnit == .hours && !sawUnit ? n * 60 : n)  // "1h30" → 30 min
            }
            number = ""
            return true
        }
        while i < chars.count {
            let c = chars[i]
            if c.isNumber || c == "." {
                number.append(c)
                i += 1
            } else if c.isLetter {
                var word = ""
                while i < chars.count, chars[i].isLetter { word.append(chars[i]); i += 1 }
                let unit: Unit?
                switch word {
                case "h", "hr", "hrs", "hour", "hours": unit = .hours
                case "m", "min", "mins", "minute", "minutes": unit = .minutes
                default: return nil
                }
                guard !number.isEmpty, flush(unit) else { return nil }
                sawUnit = true
            } else if c == " " {
                // A space between a number and its unit is fine; a dangling number is resolved at the end.
                i += 1
                if !number.isEmpty {
                    var j = i
                    while j < chars.count, chars[j] == " " { j += 1 }
                    if j < chars.count, chars[j].isLetter { continue }
                    guard flush(nil) else { return nil }
                }
            } else {
                return nil
            }
        }
        guard sawUnit || total > 0 else { return nil }
        return Int(total.rounded())
    }

    /// The canonical display form, matching what the parser accepts: "45 min", "2h", "1h 30m".
    public static func format(_ minutes: Int) -> String { MainWorkPolicy.hm(minutes) }
}
