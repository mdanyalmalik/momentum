import Foundation
import MomentumCore
import SwiftData

enum SampleData {
    /// Realistic first-run activities. The user can also choose to start empty.
    @MainActor
    static func insert(into context: ModelContext, buckets: [BucketKind: Bucket]) {
        let cal = Calendar.current
        let anchors = buckets[.anchor], main = buckets[.mainWork], hobbies = buckets[.hobby]

        let items: [Activity] = [
            Activity(name: "Morning motivation", bucket: anchors, priority: 3, minMinutes: 10, preferredMinutes: 15,
                     sessionsPerWeek: 7, isKeystone: true, sortIndex: 0,
                     notes: "Journal, plan, or something that gets you going. 10–20 minutes."),
            Activity(name: "Daily LeetCode", bucket: anchors, priority: 4, minMinutes: 20, preferredMinutes: 20,
                     sessionsPerWeek: 7, isKeystone: true, sortIndex: 1,
                     notes: "15 minutes attempting a new question, then up to 5 minutes reviewing the solution.",
                     attemptMinutes: 15, reviewMinutes: 5),
            Activity(name: "Interview preparation", bucket: main, priority: 5, minMinutes: 25, preferredMinutes: 50,
                     sessionsPerWeek: 6, deadline: cal.date(byAdding: .day, value: 12, to: .now), maxSessionsPerDay: 3,
                     sortIndex: 0, notes: "System design, behavioural stories, mock interviews."),
            Activity(name: "Master's thesis extension", bucket: main, priority: 4, minMinutes: 25, preferredMinutes: 50,
                     sessionsPerWeek: 6, maxSessionsPerDay: 3, sortIndex: 1),
            Activity(name: "Personal software project", bucket: main, priority: 3, minMinutes: 25, preferredMinutes: 50,
                     sessionsPerWeek: 4, maxSessionsPerDay: 2, sortIndex: 2),
            Activity(name: "Life admin", bucket: main, priority: 2, minMinutes: 15, preferredMinutes: 30,
                     sessionsPerWeek: 2, maxSessionsPerDay: 1, sortIndex: 3, notes: "Bills, emails, appointments."),
            Activity(name: "Gym", bucket: hobbies, priority: 4, minMinutes: 45, preferredMinutes: 60,
                     sessionsPerWeek: 3, minRestHours: 40, enjoyment: 4, sortIndex: 0,
                     notes: "At least 40h between sessions for recovery."),
            Activity(name: "Guitar practice", bucket: hobbies, priority: 3, minMinutes: 15, preferredMinutes: 30,
                     sessionsPerWeek: 3, enjoyment: 5, sortIndex: 1),
            Activity(name: "Reading", bucket: hobbies, priority: 2, minMinutes: 20, preferredMinutes: 30,
                     sessionsPerWeek: 3, enjoyment: 4, sortIndex: 2),
            Activity(name: "Music production", bucket: hobbies, priority: 2, minMinutes: 30, preferredMinutes: 60,
                     sessionsPerWeek: 1, enjoyment: 4, sortIndex: 3),
        ]
        let errands = buckets[.errand]
        let errandItems = [
            Activity(name: "Groceries", bucket: errands, minMinutes: 20, preferredMinutes: 40, sessionsPerWeek: 1, sortIndex: 0),
            Activity(name: "Renew passport", bucket: errands, priority: 4, minMinutes: 15, preferredMinutes: 30, sessionsPerWeek: 0,
                     deadline: cal.startOfDay(for: cal.date(byAdding: .day, value: 4, to: .now)!), sortIndex: 1),
            Activity(name: "Return the parcel", bucket: errands, minMinutes: 10, preferredMinutes: 15, sessionsPerWeek: 0, sortIndex: 2),
            Activity(name: "Call the bank", bucket: errands, priority: 2, minMinutes: 10, preferredMinutes: 15, sessionsPerWeek: 0, sortIndex: 3),
        ]
        for a in items + errandItems { context.insert(a) }
        if let prep = items.first(where: { $0.name.hasPrefix("Interview") }) {
            prep.estimatedWorkMinutes = 15 * 60
            prep.estimateSetAt = .now
        }
    }
}
