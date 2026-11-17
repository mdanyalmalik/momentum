import Foundation

/// CFS-style proportional sharing. Each item has a weight (from rank, × boost) and decayed service minutes.
/// Its virtual runtime is `v = service / weight`; the next slot goes to the lowest `v`.
///
/// Coming back from time away: like CFS placing a waking task, an item's `v` is never more than one session
/// below the least-served *other* item (`v ≥ min(v_others) − floor/w`). So it gets back in straight away, but
/// can't hog time to "catch up" — there is no debt.
///
/// Stickiness (granularity): the incumbent keeps the slot unless the best item is behind by more than
/// `granularity` minutes (of its own time) — runs instead of round-robin.
public enum FairShare {
    public struct Item: Hashable, Sendable {
        public var id: UUID
        public var weight: Double
        public var service: Double
        /// One session's minutes: the most an item can be "owed".
        public var floor: Double
        /// Tie-break: lower rank first.
        public var rank: Int

        public init(id: UUID, weight: Double, service: Double, floor: Double, rank: Int) {
            self.id = id
            self.weight = weight
            self.service = service
            self.floor = floor
            self.rank = rank
        }
    }

    /// Clamped virtual runtimes. `granularity` is added to the wake-up allowance so a returning item really
    /// does get back in past a sticky incumbent (one session's worth), and no more.
    public static func vruntimes(_ items: [Item], granularity: Double = 0) -> [UUID: Double] {
        let raw = items.reduce(into: [UUID: Double]()) { $0[$1.id] = $1.service / max($1.weight, 1e-6) }
        return items.reduce(into: [UUID: Double]()) { acc, i in
            let others = items.filter { $0.id != i.id }.compactMap { raw[$0.id] }
            guard let minOther = others.min() else { acc[i.id] = raw[i.id]!; return }
            acc[i.id] = max(raw[i.id]!, minOther - (i.floor + granularity) / max(i.weight, 1e-6))
        }
    }

    /// Minutes each item is ahead (+) or behind (−) of a perfectly fair split, after clamping.
    public static func lags(_ items: [Item], granularity: Double = 0) -> [UUID: Double] {
        let v = vruntimes(items, granularity: granularity)
        let totalW = items.reduce(0) { $0 + max($1.weight, 0) }
        guard totalW > 0 else { return [:] }
        // Fair virtual time: the weighted mean.
        let vFair = items.reduce(0) { $0 + v[$1.id]! * max($1.weight, 0) } / totalW
        return items.reduce(into: [UUID: Double]()) { $0[$1.id] = (v[$1.id]! - vFair) * max($1.weight, 0) }
    }

    /// Wake-up placement, done once (at the start of a day): returns each item's service raised to its clamped
    /// virtual runtime. Add the day's allocations on top of this, then `pick(…, placed: true)`.
    public static func place(_ items: [Item], granularity: Double) -> [Item] {
        let v = vruntimes(items, granularity: granularity)
        return items.map { var i = $0; i.service = v[i.id]! * max(i.weight, 1e-6); return i }
    }

    /// The lowest-v item among `allowed` (default: all), unless `incumbent` is within `granularity` minutes.
    /// With `placed`, items were already placed (no clamp now), so allocations move them normally.
    public static func pick(_ items: [Item], allowed: Set<UUID>? = nil, incumbent: UUID?, granularity: Double,
                            placed: Bool = false) -> (id: UUID, stayed: Bool)? {
        let v = placed ? items.reduce(into: [UUID: Double]()) { $0[$1.id] = $1.service / max($1.weight, 1e-6) }
                       : vruntimes(items, granularity: granularity)
        let pool = items.filter { allowed?.contains($0.id) ?? true }
        guard let best = pool.min(by: { (v[$0.id]!, $0.rank, $0.id.uuidString) < (v[$1.id]!, $1.rank, $1.id.uuidString) })
        else { return nil }
        // "Behind by" in the behind one's own minutes: how much more it would need to be level.
        if let inc = incumbent, inc != best.id, pool.contains(where: { $0.id == inc }),
           (v[inc]! - v[best.id]!) * max(best.weight, 1e-6) <= granularity {
            return (inc, true)
        }
        return (best.id, best.id == incumbent)
    }
}
