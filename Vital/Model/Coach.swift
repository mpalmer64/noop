import Foundation
import StrandAnalytics
import WhoopStore

/// Sleep coach: how much you need, how far behind you are, and when to be in bed. Need and debt come from
/// NOOP's analytics (`AnalyticsEngine.Rest`, `SleepDebt`); the bedtime is Vital's own suggestion from your
/// habitual wake time.
struct SleepCoach: Equatable {
    let needHours: Double
    let debtMin: Double
    /// Median wake time over recent nights, as minutes after midnight.
    let habitualWakeMin: Int?
    /// Suggested "in bed by" tonight, minutes after midnight.
    let bedtimeMin: Int?
    let nightsUsed: Int

    static func make(days: [DailyMetric], sessions: [CachedSleepSession], age: Int) -> SleepCoach? {
        let nights = days.suffix(28).compactMap { d -> (String, Double)? in
            guard let m = d.totalSleepMin, m > 0 else { return nil }
            return (d.day, m)
        }
        guard nights.count >= 3 else { return nil }
        let need = AnalyticsEngine.Rest.personalizedNeedHours(nightlyHours: nights.suffix(14).map { $0.1 / 60 }, age: age)
        let ledger = SleepDebt.ledger(series: nights.map { (day: $0.0, totalSleepMin: Optional($0.1)) }, needHours: need)
        // Habitual wake: median minute-of-day of recent session ends (≥ 3 h sessions only).
        let wakes = sessions
            .filter { $0.endTs - $0.effectiveStartTs >= 3 * 3600 }
            .suffix(7)
            .map { s -> Int in
                let d = Date(timeIntervalSince1970: TimeInterval(s.endTs))
                return Calendar.current.component(.hour, from: d) * 60 + Calendar.current.component(.minute, from: d)
            }
            .sorted()
        let wake = wakes.isEmpty ? nil : wakes[wakes.count / 2]
        var bed: Int?
        if let wake {
            // Need plus a third of the debt, capped at an extra hour, before the habitual wake.
            let extra = min(60.0, max(0, -ledger.balanceMin) / 3)
            let minutes = Int((need * 60 + extra).rounded())
            bed = ((wake - minutes) % 1440 + 1440) % 1440
        }
        return SleepCoach(needHours: need, debtMin: -ledger.balanceMin, habitualWakeMin: wake,
                          bedtimeMin: bed, nightsUsed: nights.count)
    }

    static func clock(_ minutes: Int) -> String {
        let d = Calendar.current.date(bySettingHour: (minutes / 60) % 24, minute: minutes % 60, second: 0, of: Date()) ?? Date()
        return d.formatted(date: .omitted, time: .shortened)
    }
}

/// Health monitor: each overnight vital against your own recent history (NOOP's `VitalBands`, the same
/// baseline fold the engine uses). Population ranges are the fallback while history is thin.
struct HealthMonitor: Equatable {
    struct Item: Equatable, Identifiable {
        let id: String
        let title: String
        let value: String
        let band: VitalBands.Band
        let nights: Int
    }
    let items: [Item]

    var outOfRange: Int { items.filter { $0.band == .outOfRange }.count }

    static func make(days: [DailyMetric], anchor: DailyMetric?, isWhoop5: Bool) -> HealthMonitor? {
        guard let a = anchor else { return nil }
        let hist = Array(days.suffix(31).dropLast())   // history before the anchor
        var items: [Item] = []
        func add(_ id: String, _ title: String, _ value: Double?, _ history: [Double?],
                 _ pop: ClosedRange<Double>, _ cfg: MetricCfg?, _ fmt: (Double) -> String) {
            let r = VitalBands.band(value: value, history: history, populationRange: pop, cfg: cfg)
            guard let value, r.band != .noData else { return }
            items.append(Item(id: id, title: title, value: fmt(value), band: r.band, nights: r.nights))
        }
        add("rhr", "Resting HR", a.restingHr.map(Double.init), hist.map { $0.restingHr.map(Double.init) },
            40...100, Baselines.restingHRCfg) { "\(Int($0)) bpm" }
        add("hrv", "HRV", a.avgHrv, hist.map(\.avgHrv), 15...200, Baselines.hrvCfg) { "\(Int($0.rounded())) ms" }
        add("resp", "Respiration", a.respRateBpm, hist.map(\.respRateBpm), 11...20, Baselines.respCfg) { String(format: "%.1f rpm", $0) }
        if let t = a.skinTempDevC, !VitalBands.isAbsoluteSkinTemp(t) {
            add("skin", "Skin temp", t, hist.map(\.skinTempDevC), -1.0...1.0, VitalBands.skinTempDeviationCfg) { VitalUnits.temperatureDelta(celsius: $0) }
        }
        if !isWhoop5 {
            add("spo2", "Blood oxygen", a.spo2Pct, hist.map(\.spo2Pct), 94...100, nil) { "\(Int($0.rounded()))%" }
        }
        return items.isEmpty ? nil : HealthMonitor(items: items)
    }
}
