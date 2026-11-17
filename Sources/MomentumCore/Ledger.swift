import Foundation

/// Free time within a day's waking window, after subtracting hard constraints.
struct FreeTime {
    private(set) var intervals: [DateInterval]

    init(window: DateInterval, busy: [DateInterval]) {
        var result = [window]
        for b in busy {
            result = result.flatMap { Self.subtract(b, from: $0) }
        }
        intervals = result.filter { $0.duration >= 60 }.sorted { $0.start < $1.start }
    }

    static func subtract(_ b: DateInterval, from a: DateInterval) -> [DateInterval] {
        guard b.start < a.end, b.end > a.start else { return [a] }
        var out: [DateInterval] = []
        if b.start > a.start { out.append(DateInterval(start: a.start, end: b.start)) }
        if b.end < a.end { out.append(DateInterval(start: b.end, end: a.end)) }
        return out
    }

    var totalMinutes: Int { Int(intervals.reduce(0) { $0 + $1.duration } / 60) }

    func firstSlot(minutes: Int, notBefore: Date) -> Date? {
        let need = Double(minutes) * 60
        for i in intervals {
            let s = max(i.start, notBefore)
            if s < i.end, i.end.timeIntervalSince(s) >= need - 0.5 { return s }
        }
        return nil
    }

    /// The earliest gap where at least `minimum` fits; uses up to `preferred` of it. Lets a session
    /// use the time before you sleep (shortened) instead of skipping to the next day-part.
    func firstFlexibleSlot(minimum: Int, preferred: Int, notBefore: Date) -> (start: Date, minutes: Int)? {
        for i in intervals {
            let s = max(i.start, notBefore)
            guard s < i.end else { continue }
            let available = Int(i.end.timeIntervalSince(s) / 60)
            if available >= minimum { return (s, min(preferred, available)) }
        }
        return nil
    }

    func fits(_ i: DateInterval) -> Bool {
        intervals.contains { $0.start <= i.start && $0.end >= i.end }
    }

    mutating func reserve(_ r: DateInterval) {
        intervals = intervals.flatMap { Self.subtract(r, from: $0) }.filter { $0.duration >= 60 }
    }
}

/// Service received by each activity: completed history plus sessions already planned earlier in the horizon.
/// This is the scheduler's equivalent of a CPU scheduler's accounting of runtime per process.
struct ServiceLedger {
    struct Entry {
        let start: Date
        let minutes: Int
        var end: Date { start.addingTimeInterval(Double(minutes) * 60) }
    }

    private var entries: [UUID: [Entry]] = [:]

    init(history: [SessionRecord]) {
        for r in history where r.outcome == .completed {
            entries[r.activityID, default: []].append(Entry(start: r.start, minutes: r.minutes))
        }
    }

    mutating func add(_ id: UUID, start: Date, minutes: Int) {
        entries[id, default: []].append(Entry(start: start, minutes: minutes))
    }

    func lastStart(_ id: UUID, before: Date) -> Date? {
        entries[id]?.filter { $0.start < before }.map(\.start).max()
    }

    func minutes(_ id: UUID, from: Date, to: Date) -> Int {
        (entries[id] ?? []).filter { $0.start >= from && $0.start < to }.reduce(0) { $0 + $1.minutes }
    }

    func count(_ id: UUID, from: Date, to: Date) -> Int {
        (entries[id] ?? []).filter { $0.start >= from && $0.start < to }.count
    }

    /// Hard recovery constraint: at least `restHours` between the end of any session and the start of another.
    /// Minutes of service before `at`, each weighted by 2^(−age / halfLife): recent time counts fully,
    /// older time fades. This replaces weekly windows — nothing resets on a Monday.
    func decayedMinutes(_ id: UUID, at: Date, halfLifeDays: Double) -> Double {
        let halfLife = max(halfLifeDays, 0.1) * 86_400
        return (entries[id] ?? []).reduce(0) { acc, e in
            guard e.start < at else { return acc }
            return acc + Double(e.minutes) * pow(2, -at.timeIntervalSince(e.start) / halfLife)
        }
    }

    /// Planned-but-optional sessions: don't count as service, but still need recovery around them.
    private var restOnly: [UUID: [Entry]] = [:]

    mutating func addRestOnly(_ id: UUID, start: Date, minutes: Int) {
        restOnly[id, default: []].append(Entry(start: start, minutes: minutes))
    }

    func recoveryOK(_ id: UUID, start: Date, minutes: Int, restHours: Double) -> Bool {
        guard restHours > 0 else { return true }
        let rest = restHours * 3600
        let end = start.addingTimeInterval(Double(minutes) * 60)
        for e in (entries[id] ?? []) + (restOnly[id] ?? []) {
            let gap = e.start >= start ? e.start.timeIntervalSince(end) : start.timeIntervalSince(e.end)
            if gap < rest - 1 { return false }
        }
        return true
    }

    func consecutiveDays(_ id: UUID, before day: Date, calendar: Calendar) -> Int {
        var n = 0
        var d = day
        while n < 30, let prev = calendar.date(byAdding: .day, value: -1, to: d), count(id, from: prev, to: d) > 0 {
            n += 1
            d = prev
        }
        return n
    }
}
