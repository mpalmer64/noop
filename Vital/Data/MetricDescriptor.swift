import Foundation
import SwiftUI
import WhoopStore

/// Every metric a tile can drill into. Adding one is a new case plus a descriptor below, never a screen.
enum MetricID: String, CaseIterable, Identifiable, Hashable {
    case recovery, strain, hrv, rhr, hr, sleepPerformance, sleepHours, spo2, skinTemp, respRate, steps, activeKcal, battery
    var id: String { rawValue }
}

enum TimeRange: String, CaseIterable, Identifiable, Hashable {
    case day, week, month, sixMonths
    var id: String { rawValue }
    var label: String {
        switch self {
        case .day: return "Day"
        case .week: return "Week"
        case .month: return "Month"
        case .sixMonths: return "6M"
        }
    }
    /// Trailing-window length in days; 1 for the date-anchored Day range.
    var days: Int {
        switch self {
        case .day: return 1
        case .week: return 7
        case .month: return 30
        case .sixMonths: return 182
        }
    }
}

/// How a value is rendered. Formatting lives with the unit so one descriptor field decides it everywhere.
enum MetricUnit {
    case percent, bpm, ms, rpm, hours, count, kcal, strain, skinTemp

    var label: String {
        switch self {
        case .percent: return "%"
        case .bpm: return "bpm"
        case .ms: return "ms"
        case .rpm: return "rpm"
        case .hours: return "h"
        case .kcal: return "kcal"
        case .count, .skinTemp: return ""
        case .strain: return "of 21"
        }
    }

    var decimals: Int {
        switch self {
        case .strain, .hours, .rpm: return 1
        default: return 0
        }
    }

    func format(_ v: Double?) -> String {
        guard let v else { return "--" }
        switch self {
        case .hours: return VFormat.hoursMinutes(v * 60)
        case .skinTemp:
            // The stored value is bimodal (WhoopImporter): absolute °C from an export, a deviation on-device.
            return v > 20 ? VitalUnits.temperature(celsius: v) : VitalUnits.temperatureDelta(celsius: v)
        case .count, .kcal: return v.rounded().formatted(.number.precision(.fractionLength(0)))
        default: return decimals == 0 ? "\(Int(v.rounded()))" : String(format: "%.\(decimals)f", v)
        }
    }

    /// Compact axis/tick formatting (no unit suffix).
    func short(_ v: Double) -> String {
        switch self {
        case .hours: return String(format: "%.1f", v)
        case .skinTemp: return v > 20 ? VitalUnits.temperature(celsius: v) : VitalUnits.temperatureDelta(celsius: v)
        default: return decimals == 0 ? "\(Int(v.rounded()))" : String(format: "%.\(decimals)f", v)
        }
    }
}

enum Aggregation {
    case mean, min, max, sum, last

    func apply(_ xs: [Double]) -> Double? {
        guard !xs.isEmpty else { return nil }
        switch self {
        case .mean: return xs.reduce(0, +) / Double(xs.count)
        case .min: return xs.min()
        case .max: return xs.max()
        case .sum: return xs.reduce(0, +)
        case .last: return xs.last
        }
    }

    var label: String {
        switch self {
        case .mean: return "avg"
        case .min: return "min"
        case .max: return "max"
        case .sum: return "total"
        case .last: return "latest"
        }
    }
}

/// Where a Day-range series comes from.
enum IntradaySource {
    /// NOOP's Deep-Timeline read (`Repository.timelineSeries`): adaptive buckets, strap union, family-aware
    /// unit conversion. HR and skin temperature ride this.
    case timeline(Repository.TimelineMetric)
    /// Battery state of charge from the raw sample table.
    case battery
}

/// Where Week / Month / 6M points come from.
enum DailyKey {
    /// A column on `DailyMetric` (already in `repo.days`; no query).
    case column((DailyMetric) -> Double?)
    /// A `metricSeries` key with no daily column (via `Repository.exploreSeries`, imported-wins layering).
    case series(String)
    /// SQL-bucketed heart rate over the whole window (hourly for a week, six-hourly for a month, daily
    /// for six months). Never touches raw 1 Hz rows.
    case hrBuckets
}

/// What the Day tab shows for a metric that is computed once per day (one point is not a chart).
enum DayInputs {
    /// HRV, resting HR, respiration and sleep performance, each against its baseline.
    case recoveryInputs
    /// The day's HR curve with zone shading plus the sessions that contributed.
    case strainInputs
    /// Straight into that night's detail.
    case night
    /// A single summary card (steps, SpO₂ nightly mean, …).
    case summary
}

struct VMetric: Identifiable {
    let id: MetricID
    let title: String
    let unit: MetricUnit
    /// nil = daily-only metric; the Day tab renders `dayInputs` instead of a line.
    let intraday: IntradaySource?
    /// nil = no daily form (battery); the range picker offers Day only.
    let dailyKey: DailyKey?
    let aggregation: Aggregation
    /// Qualitative banding for colour; nil = neutral.
    let band: (Double) -> VitalBand?
    let tint: Color
    let systemImage: String
    /// Fixed y-domain (scores); nil = fit to data.
    let domain: ClosedRange<Double>?
    /// Bars read better than lines for per-night totals and counts.
    var bars = false
    var dayInputs: DayInputs = .summary
    /// One line of provenance shown under the chart.
    var note: String? = nil
    /// Where a lower value is the better one (resting HR).
    var lowerIsBetter = false
    /// Sibling metrics the detail offers at the bottom so the user moves sideways, not back-back-back.
    var related: [MetricID] { VMetric.relatedMap[id] ?? [] }
    /// Two or three sentences: what it is and how Vital derives it. Neutral project voice, no medical claims.
    var about: String { VMetric.aboutMap[id] ?? "" }

    /// Ranges the picker offers. Daily-only metrics lead with Week (a one-point Day is not the headline);
    /// intraday metrics lead with Day.
    var ranges: [TimeRange] {
        guard dailyKey != nil else { return [.day] }
        return intraday == nil ? [.week, .month, .sixMonths, .day] : TimeRange.allCases
    }
    var defaultRange: TimeRange { intraday == nil ? .week : .day }

    /// The tile value for a scored day. Column metrics read the row; series metrics need the resolved
    /// series value for that day (Rest lives outside `DailyMetric`). This is what the Week series' last
    /// point must equal — see VitalTests.
    func tileValue(anchor: DailyMetric?, seriesValue: Double?) -> Double? {
        guard let dailyKey else { return nil }
        switch dailyKey {
        case .column(let pick): return anchor.flatMap(pick)
        case .series: return seriesValue
        case .hrBuckets: return nil
        }
    }

    func color(for value: Double?) -> Color {
        guard let value, let b = band(value) else { return tint }
        switch b {
        case .low: return VColor.recoveryLow
        case .mid: return VColor.recoveryMid
        case .high: return VColor.recoveryHigh
        }
    }
}

extension VMetric {
    static func descriptor(_ id: MetricID) -> VMetric {
        switch id {
        case .recovery:
            return VMetric(id: id, title: "Recovery", unit: .percent, intraday: nil,
                                    dailyKey: .column { $0.recovery }, aggregation: .mean,
                                    band: { VitalBand.recovery($0) }, tint: VColor.recoveryHigh,
                                    systemImage: "circle.circle", domain: 0...100, dayInputs: .recoveryInputs,
                                    note: "HRV, resting heart rate, respiration and sleep against your own baselines.")
        case .strain:
            return VMetric(id: id, title: "Strain", unit: .strain, intraday: nil,
                                    dailyKey: .column { $0.strain.map { $0 * 21 / 100 } }, aggregation: .mean,
                                    band: { _ in nil }, tint: VColor.strain, systemImage: "flame.fill",
                                    domain: 0...21, dayInputs: .strainInputs,
                                    note: "Accrues from time in heart-rate zones across the whole day.")
        case .hrv:
            return VMetric(id: id, title: "HRV", unit: .ms, intraday: nil,
                                    dailyKey: .column { $0.avgHrv }, aggregation: .mean,
                                    band: { _ in nil }, tint: VColor.hrv, systemImage: "waveform.path", domain: nil,
                                    note: "Overnight RMSSD during the main sleep.")
        case .rhr:
            return VMetric(id: id, title: "Resting heart rate", unit: .bpm, intraday: nil,
                                    dailyKey: .column { $0.restingHr.map(Double.init) }, aggregation: .mean,
                                    band: { _ in nil }, tint: VColor.rhr, systemImage: "heart.fill", domain: nil,
                                    note: "Lowest sustained heart rate overnight.", lowerIsBetter: true)
        case .hr:
            return VMetric(id: id, title: "Heart rate", unit: .bpm, intraday: .timeline(.hr),
                                    dailyKey: .hrBuckets, aggregation: .mean,
                                    band: { _ in nil }, tint: VColor.heart, systemImage: "heart.fill", domain: nil,
                                    note: "Each point is the mean of the strap's readings in that bucket.")
        case .sleepPerformance:
            return VMetric(id: id, title: "Sleep performance", unit: .percent, intraday: nil,
                                    dailyKey: .series("sleep_performance"), aggregation: .mean,
                                    band: { VitalBand.recovery($0) }, tint: VColor.sleep,
                                    systemImage: "moon.zzz.fill", domain: 0...100, dayInputs: .night,
                                    note: "Hours slept against your personalised need.")
        case .sleepHours:
            return VMetric(id: id, title: "Sleep", unit: .hours, intraday: nil,
                                    dailyKey: .column { $0.totalSleepMin.map { $0 / 60 } }, aggregation: .mean,
                                    band: { _ in nil }, tint: VColor.sleep, systemImage: "bed.double.fill", domain: nil,
                                    bars: true, dayInputs: .night, note: "Time asleep, filed under the night's wake date.")
        case .spo2:
            return VMetric(id: id, title: "Blood oxygen", unit: .percent, intraday: nil,
                                    dailyKey: .column { $0.spo2Pct }, aggregation: .mean,
                                    band: { _ in nil }, tint: VColor.oxygen, systemImage: "drop.fill", domain: 90...100,
                                    note: "Nightly mean during sleep. The strap's raw optical track is a red/IR ratio, not a percentage, so there is no intraday line.")
        case .skinTemp:
            return VMetric(id: id, title: "Skin temperature", unit: .skinTemp, intraday: .timeline(.skinTemp),
                                    dailyKey: .series("skin_temp"), aggregation: .mean,
                                    band: { _ in nil }, tint: VColor.temperature, systemImage: "thermometer.medium", domain: nil,
                                    note: "Nights from a WHOOP export are absolute readings; nights staged on this phone are deviations from your baseline.")
        case .respRate:
            return VMetric(id: id, title: "Respiratory rate", unit: .rpm, intraday: nil,
                                    dailyKey: .column { $0.respRateBpm }, aggregation: .mean,
                                    band: { _ in nil }, tint: VColor.respiration, systemImage: "lungs.fill", domain: nil,
                                    note: "Breaths per minute during sleep. The raw respiration waveform is not a rate, so there is no intraday line.")
        case .steps:
            return VMetric(id: id, title: "Steps", unit: .count, intraday: nil,
                                    dailyKey: .column { $0.steps.map(Double.init) }, aggregation: .mean,
                                    band: { _ in nil }, tint: VColor.strain, systemImage: "figure.walk", domain: nil,
                                    bars: true, note: "Daily total from the strap's step counter or the imported activity file.")
        case .activeKcal:
            return VMetric(id: id, title: "Active energy", unit: .kcal, intraday: nil,
                           dailyKey: .column { $0.activeKcalEst }, aggregation: .mean,
                           band: { _ in nil }, tint: VColor.rhr, systemImage: "flame", domain: nil,
                           bars: true, note: "Whole-day estimate from heart rate alone; it does not include resting metabolism.")
        case .battery:
            return VMetric(id: id, title: "Battery", unit: .percent, intraday: .battery, dailyKey: nil,
                                    aggregation: .last, band: { _ in nil }, tint: VColor.textSecondary,
                                    systemImage: "battery.75percent", domain: 0...100,
                                    note: "State of charge the strap reported through the day.")
        }
    }

    static let all: [VMetric] = MetricID.allCases.map(descriptor)

    static let relatedMap: [MetricID: [MetricID]] = [
        .recovery: [.hrv, .rhr, .sleepPerformance],
        .strain: [.hr, .steps, .activeKcal],
        .hrv: [.recovery, .rhr, .respRate],
        .rhr: [.recovery, .hrv, .hr],
        .hr: [.strain, .rhr, .hrv],
        .sleepPerformance: [.sleepHours, .hr, .respRate],
        .sleepHours: [.sleepPerformance, .recovery],
        .spo2: [.respRate, .skinTemp],
        .skinTemp: [.recovery, .respRate],
        .respRate: [.recovery, .hrv],
        .steps: [.strain, .activeKcal],
        .activeKcal: [.strain, .steps],
        .battery: [],
    ]

    static let aboutMap: [MetricID: String] = [
        .recovery: "Recovery is a 0–100 score of how ready the body looks this morning. Vital takes overnight HRV, resting heart rate, respiratory rate and sleep performance from the strap's offload and compares each with your own recent baseline; the score is computed on this phone by NOOP's engine, the same one NOOP uses.",
        .strain: "Strain is cardiovascular load on WHOOP's 0–21 scale. Every banked heart-rate sample is weighted by the zone it falls in (relative to your max heart rate), and the weighted time is integrated across the day, so a long easy day and a short hard one can land in the same place.",
        .hrv: "Heart-rate variability is the beat-to-beat variation in your heart rhythm, reported as RMSSD in milliseconds from the main sleep. Higher than your own baseline usually reads as better recovered; the absolute number varies a lot between people, so the trend matters more than the value.",
        .rhr: "Resting heart rate is the lowest sustained heart rate during the main sleep, in beats per minute. It is measured directly from the strap's overnight samples; a rise against your baseline is one of the inputs that lowers recovery.",
        .hr: "Heart rate is the strap's optical reading, about once a second. The Day view averages readings into short buckets so a whole day draws quickly; longer ranges average further. Live readings on Today arrive over Bluetooth while the strap is connected.",
        .sleepPerformance: "Sleep performance is hours slept as a percentage of the sleep you needed that night. Need is personalised from your recent nights and age; the night's duration comes from the strap's staged sleep, or from the WHOOP export for imported nights.",
        .sleepHours: "Time asleep for each night, filed under the day the night ended on. Nights staged on this phone come from overnight heart rate and motion; imported nights carry the export's totals.",
        .spo2: "Blood oxygen is the mean saturation during sleep, from the strap's red and infrared optical channels on a WHOOP 4.0. A 5.0 / MG has no SpO₂ channel, so this stays empty on those straps.",
        .skinTemp: "Skin temperature from the strap's wrist sensor. Nights staged on this phone are shown as a deviation from your baseline; nights from a WHOOP export are absolute readings, so the two are labelled differently.",
        .respRate: "Respiratory rate is breaths per minute during sleep. On a 5.0 / MG it is estimated from the timing between heartbeats; on a 4.0 it comes from the strap's respiration track.",
        .steps: "Daily steps from the strap's step counter (5.0 / MG) or the imported activity file. A 4.0 has no step counter, so days from that strap have no value.",
        .activeKcal: "Active energy is a whole-day estimate from heart rate alone, using your profile. It does not include resting metabolism and is an approximation, not a measurement.",
        .battery: "The strap's reported state of charge through the day, as delivered over Bluetooth while connected.",
    ]
}
