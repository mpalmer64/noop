import Foundation
import StrandAnalytics
import WhoopStore

/// Daily journal (WHOOP-style behaviours) and their measured effect on recovery. Answers persist through
/// NOOP's `Repository.saveJournalAnswer`, so imported WHOOP journal rows and Vital's own answers pool into
/// one history; effects come from NOOP's `BehaviorInsights`.
enum VitalJournal {
    /// NOOP's default question set, verbatim, so imported WHOOP rows ("Did you drink any alcohol?") and
    /// Vital answers share keys.
    static let questions: [String] = [
        "Did you drink any alcohol?",
        "Did you have caffeine late in the day?",
        "Did you view a screen in bed?",
        "Did you eat close to bedtime?",
        "Did you feel stressed?",
        "Did you use a sauna?",
        "Did you share your bed?",
        "Did you feel sick or ill?",
        "Did you take magnesium?",
        "Did you read before bed?",
    ]

    static func shortLabel(_ q: String) -> String {
        switch q {
        case "Did you drink any alcohol?": return "Alcohol"
        case "Did you have caffeine late in the day?": return "Late caffeine"
        case "Did you view a screen in bed?": return "Screen in bed"
        case "Did you eat close to bedtime?": return "Late meal"
        case "Did you feel stressed?": return "Stressed"
        case "Did you use a sauna?": return "Sauna"
        case "Did you share your bed?": return "Shared bed"
        case "Did you feel sick or ill?": return "Felt sick"
        case "Did you take magnesium?": return "Magnesium"
        case "Did you read before bed?": return "Read before bed"
        default: return q.replacingOccurrences(of: "Did you ", with: "").replacingOccurrences(of: "?", with: "").capitalized
        }
    }

    /// Ranked behaviour effects on an outcome (recovery / HRV / sleep), significant ones first.
    static func effects(entries: [JournalEntry], days: [DailyMetric],
                        outcome: (DailyMetric) -> Double?, outcomeName: String) -> [BehaviorEffect] {
        var yes: [String: Set<String>] = [:]
        var no: [String: Set<String>] = [:]
        for e in entries {
            if e.answeredYes { yes[e.question, default: []].insert(e.day) } else { no[e.question, default: []].insert(e.day) }
        }
        var byDay: [String: Double] = [:]
        for d in days { if let v = outcome(d) { byDay[d.day] = v } }
        return BehaviorInsights.rank(behaviors: yes, controls: no, outcomeByDay: byDay, outcome: outcomeName)
            .sorted { a, b in
                if a.significant != b.significant { return a.significant }
                return abs(a.delta) > abs(b.delta)
            }
    }
}

@MainActor
extension VitalModel {
    /// Native answers plus the imported WHOOP journal (Repository keeps them apart; insights want both).
    func journalEntries() async -> [JournalEntry] {
        let native = await repo.journalEntries(days: 800)
        let imported = await repo.importedJournalEntries(days: 800)
        var seen = Set<String>()
        return (native + imported).filter { seen.insert($0.day + "|" + $0.question).inserted }
    }

    /// Answers already logged for a day, keyed by question.
    func journalAnswers(day: String) async -> [String: Bool] {
        let all = await journalEntries()
        var out: [String: Bool] = [:]
        for e in all where e.day == day { out[e.question] = e.answeredYes }
        return out
    }

    func answerJournal(day: String, question: String, yes: Bool) async {
        await repo.saveJournalAnswer(day: day, question: question, answeredYes: yes)
    }
}
