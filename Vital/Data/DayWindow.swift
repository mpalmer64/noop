import Foundation
import StrandAnalytics
import WhoopStore

/// The one place Vital turns an instant into a scored-day key and back.
///
/// `DailyMetric` rows are keyed by the LOCAL calendar day the engine derived with
/// `AnalyticsEngine.dayString(ts, offsetSec: TimeZone.current.secondsFromGMT())`
/// (IntelligenceEngine's `tzOffset`), and a night is filed under the day it ENDS on. Every read in the
/// drill-down resolves its window through here so a tile and its detail describe the same hours; a second
/// convention anywhere is the off-by-one bug the spec warns about.
enum VitalDay {
    /// Seconds east of UTC, as the engine reads it at scoring time.
    static var tzOffset: Int { TimeZone.current.secondsFromGMT() }

    private static let iso: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// Day key for a unix-seconds instant. Same function scoring used to bucket the sample.
    static func key(forTs ts: Int, tzOffset: Int = VitalDay.tzOffset) -> String {
        AnalyticsEngine.dayString(ts, offsetSec: tzOffset)
    }

    static func key(for date: Date, tzOffset: Int = VitalDay.tzOffset) -> String {
        key(forTs: Int(date.timeIntervalSince1970.rounded(.down)), tzOffset: tzOffset)
    }

    static func todayKey(now: Date = Date()) -> String { key(for: now) }

    /// The inclusive unix-seconds window `[start, start + 86399]` whose every instant maps back to `key`.
    /// nil for a malformed key.
    static func window(forKey key: String, tzOffset: Int = VitalDay.tzOffset) -> ClosedRange<Int>? {
        guard let utcMidnight = iso.date(from: key) else { return nil }
        let start = Int(utcMidnight.timeIntervalSince1970) - tzOffset
        return start...(start + 86_399)
    }

    /// `key` moved by `days` calendar days (negative = earlier). nil for a malformed key.
    static func shifted(_ key: String, by days: Int) -> String? {
        guard let d = iso.date(from: key) else { return nil }
        return iso.string(from: d.addingTimeInterval(TimeInterval(days) * 86_400))
    }

    /// Whole-day count `to - from`; nil when either key is malformed.
    static func distance(from: String, to: String) -> Int? {
        guard let a = iso.date(from: from), let b = iso.date(from: to) else { return nil }
        return Int(((b.timeIntervalSince1970 - a.timeIntervalSince1970) / 86_400).rounded())
    }

    /// A night belongs to the day it ENDS on. Same rule the engine applies when it attributes a session's
    /// sleep total to a `DailyMetric` (`dayString(endTs, offsetSec:)`).
    static func wakeDayKey(_ s: CachedSleepSession, tzOffset: Int = VitalDay.tzOffset) -> String {
        key(forTs: s.endTs, tzOffset: tzOffset)
    }

    /// Local midnight `Date` for a key, for chart axes. nil for a malformed key.
    static func date(forKey key: String, tzOffset: Int = VitalDay.tzOffset) -> Date? {
        window(forKey: key, tzOffset: tzOffset).map { Date(timeIntervalSince1970: TimeInterval($0.lowerBound)) }
    }
}
