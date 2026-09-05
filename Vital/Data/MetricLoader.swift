import Foundation
import StrandAnalytics
import WhoopProtocol
import StrandDesign
import WhoopStore

/// One chart point. `ts` is unix seconds (bucket start for intraday, local midnight for daily).
struct VPoint: Identifiable, Equatable, Sendable {
    let ts: Int
    let value: Double
    var id: Int { ts }
    var date: Date { Date(timeIntervalSince1970: TimeInterval(ts)) }
}

struct MetricSeries: Equatable, Sendable {
    var points: [VPoint] = []
    /// Bucket width for intraday series; 0 for one-point-per-day series.
    var bucketSeconds = 0
    /// Days the trailing window spans (Week/Month/6M), for the "n of m days" line.
    var windowDays = 0
    static let empty = MetricSeries()
}

/// Cache key. Trailing windows anchor on today; Day anchors on the date being viewed.
struct MetricQuery: Hashable {
    let id: MetricID
    let range: TimeRange
    let anchorKey: String
}

/// Per-(metric, range, anchor) results. Switching Week → Month → Week must not re-query; a completed
/// offload or import clears everything (`VitalModel.refreshAfterSync` / `runScoring`).
@MainActor
final class MetricCache: ObservableObject {
    /// Bumps on invalidate so open detail views reload.
    @Published private(set) var version = 0
    private var entries: [MetricQuery: MetricSeries] = [:]

    func cached(_ q: MetricQuery) -> MetricSeries? { entries[q] }
    func set(_ q: MetricQuery, _ s: MetricSeries) { entries[q] = s }
    func invalidate() {
        entries.removeAll()
        version += 1
    }
}

/// Pure shaping helpers, unit-tested without a store.
enum MetricSeriesBuilder {
    /// Trailing window of `range.days` days ending at `endKey` (inclusive).
    static func trailingWindow(_ range: TimeRange, endKey: String) -> (from: String, to: String) {
        (VitalDay.shifted(endKey, by: -(range.days - 1)) ?? endKey, endKey)
    }

    /// One point per scored day in `[from, to]` for a daily descriptor. Column keys read the row; series keys
    /// read the resolved `seriesByDay`. Sorted ascending by day; days without a value are skipped.
    static func daily(_ d: VMetric, days: [DailyMetric], seriesByDay: [String: Double],
                      from: String, to: String, tzOffset: Int = VitalDay.tzOffset) -> [VPoint] {
        guard let key = d.dailyKey else { return [] }
        var out: [VPoint] = []
        switch key {
        case .column(let pick):
            for row in days where row.day >= from && row.day <= to {
                if let v = pick(row), let w = VitalDay.window(forKey: row.day, tzOffset: tzOffset) {
                    out.append(VPoint(ts: w.lowerBound, value: v))
                }
            }
        case .series:
            for (day, v) in seriesByDay where day >= from && day <= to {
                if let w = VitalDay.window(forKey: day, tzOffset: tzOffset) { out.append(VPoint(ts: w.lowerBound, value: v)) }
            }
        case .hrBuckets:
            return []
        }
        return out.sorted { $0.ts < $1.ts }
    }

    /// Mean-bucket `points` down to about `target` for display. Already-small series pass through.
    static func downsample(_ points: [VPoint], target: Int) -> [VPoint] {
        guard points.count > target, target > 0, let first = points.first, let last = points.last else { return points }
        let span = max(1, last.ts - first.ts)
        let width = max(1, span / target)
        var sums: [Int: (sum: Double, n: Int)] = [:]
        for p in points {
            let k = (p.ts - first.ts) / width
            let cur = sums[k] ?? (0, 0)
            sums[k] = (cur.sum + p.value, cur.n + 1)
        }
        return sums.keys.sorted().map { k in VPoint(ts: first.ts + k * width, value: sums[k]!.sum / Double(sums[k]!.n)) }
    }

    /// Mean bpm per fixed window of raw samples, dropping empty windows so a sparkline stays continuous.
    /// (Was `NowScreen.bucket`; shared by the Today HR card, Sleep, Nights and Activities.)
    static func bucketMeans(_ samples: [HRSample], seconds: Int) -> [Double] {
        guard let first = samples.first?.ts, seconds > 0 else { return [] }
        var sums: [Int: (sum: Double, n: Int)] = [:]
        for s in samples {
            let k = (s.ts - first) / seconds
            let cur = sums[k] ?? (0, 0)
            sums[k] = (cur.sum + Double(s.bpm), cur.n + 1)
        }
        return sums.keys.sorted().map { sums[$0]!.sum / Double(sums[$0]!.n) }
    }

    /// Bucket width for HR over a trailing window: hourly for a week, six-hourly for a month, daily for six
    /// months. Keeps every window at ≤ ~180 points and never reads raw rows.
    static func hrBucketSeconds(_ range: TimeRange) -> Int {
        switch range {
        case .day: return 60
        case .week: return 3600
        case .month: return 6 * 3600
        case .sixMonths: return 86_400
        }
    }
}

// MARK: - Loading

@MainActor
extension VitalModel {
    /// The series for a descriptor/range, cached. Day anchors on `anchorKey`; trailing ranges anchor on
    /// today (the key is normalised so the cache hits regardless of what the view passed).
    func metricSeries(_ d: VMetric, range: TimeRange, anchorKey: String) async -> MetricSeries {
        let anchor = range == .day ? anchorKey : VitalDay.todayKey()
        let q = MetricQuery(id: d.id, range: range, anchorKey: anchor)
        if let hit = metricCache.cached(q) { return hit }
        let s: MetricSeries
        if range == .day {
            s = await loadDay(d, key: anchor)
        } else {
            s = await loadTrailing(d, range: range, endKey: anchor)
        }
        metricCache.set(q, s)
        return s
    }

    private func loadDay(_ d: VMetric, key: String) async -> MetricSeries {
        guard let w = VitalDay.window(forKey: key), let src = d.intraday else { return .empty }
        switch src {
        case .timeline(let metric):
            let t = await repo.timelineSeries(metric: metric, from: w.lowerBound, to: w.upperBound, targetPoints: 500)
            let pts = t.points.map { VPoint(ts: Int($0.date.timeIntervalSince1970), value: $0.value) }
            return MetricSeries(points: MetricSeriesBuilder.downsample(pts, target: 500),
                                bucketSeconds: t.isRaw ? 1 : t.bucketSeconds, windowDays: 1)
        case .battery:
            guard let store = await repo.storeHandle() else { return .empty }
            var byTs: [Int: Double] = [:]
            for id in repo.importedReadIds.reversed() {
                let rows = (try? await store.batterySamples(deviceId: id, from: w.lowerBound, to: w.upperBound, limit: 20_000)) ?? []
                for r in rows { if let soc = r.soc { byTs[r.ts] = soc } }
            }
            let pts = byTs.keys.sorted().map { VPoint(ts: $0, value: byTs[$0]!) }
            return MetricSeries(points: MetricSeriesBuilder.downsample(pts, target: 300), bucketSeconds: 0, windowDays: 1)
        }
    }

    private func loadTrailing(_ d: VMetric, range: TimeRange, endKey: String) async -> MetricSeries {
        guard let key = d.dailyKey else { return .empty }
        let (from, to) = MetricSeriesBuilder.trailingWindow(range, endKey: endKey)
        switch key {
        case .column:
            return MetricSeries(points: MetricSeriesBuilder.daily(d, days: repo.days, seriesByDay: [:], from: from, to: to),
                                windowDays: range.days)
        case .series(let seriesKey):
            let rows = await repo.exploreSeries(key: seriesKey, source: Self.deviceId, days: range.days + 2)
            let byDay = Dictionary(rows.map { ($0.day, $0.value) }, uniquingKeysWith: { _, last in last })
            return MetricSeries(points: MetricSeriesBuilder.daily(d, days: [], seriesByDay: byDay, from: from, to: to),
                                windowDays: range.days)
        case .hrBuckets:
            guard let lo = VitalDay.window(forKey: from)?.lowerBound, let hi = VitalDay.window(forKey: to)?.upperBound else { return .empty }
            let bucket = MetricSeriesBuilder.hrBucketSeconds(range)
            let rows = await repo.hrBuckets(from: lo, to: hi, bucketSeconds: bucket)
            return MetricSeries(points: rows.map { VPoint(ts: $0.ts, value: $0.bpm) }, bucketSeconds: bucket, windowDays: range.days)
        }
    }

    /// The resolved series value for one day (Rest and skin temp live outside `DailyMetric`).
    func seriesValue(_ d: VMetric, day: String) async -> Double? {
        guard case .series(let k)? = d.dailyKey else { return nil }
        let rows = await repo.exploreSeries(key: k, source: Self.deviceId, days: 4000)
        return rows.last(where: { $0.day == day })?.value
    }

    /// Rest (sleep performance) by day over the whole history; feeds the recovery-inputs baseline.
    func restByDay() async -> [String: Double] {
        let rows = await repo.exploreSeries(key: "sleep_performance", source: Self.deviceId, days: 4000)
        return Dictionary(rows.map { ($0.day, $0.value) }, uniquingKeysWith: { _, last in last })
    }

    /// The main sleep that ended on `wakeKey` (longest block whose wake day matches), or nil.
    func night(forWakeDay wakeKey: String) async -> CachedSleepSession? {
        guard let w = VitalDay.window(forKey: wakeKey) else { return nil }
        let rows = await repo.sleepSessions(from: w.lowerBound - 36 * 3600, to: w.upperBound, limit: 40)
        return rows.filter { VitalDay.wakeDayKey($0) == wakeKey && $0.endTs > $0.effectiveStartTs }
            .max { ($0.endTs - $0.effectiveStartTs) < ($1.endTs - $1.effectiveStartTs) }
    }
}

// MARK: - Day inputs

/// One input behind a recovery score, against the personal baseline NOOP's engine folds.
struct RecoveryInput: Identifiable, Equatable {
    let id: MetricID
    let title: String
    let value: Double?
    let baseline: Double?
    let nights: Int
    let unit: MetricUnit
    let lowerIsBetter: Bool

    var deviationPct: Double? {
        guard let value, let baseline, baseline != 0 else { return nil }
        return (value - baseline) / baseline * 100
    }
}

enum RecoveryInputs {
    /// The four inputs for `dayKey`, with baselines folded over the 60 scored days strictly before it
    /// (`Baselines.foldHistory`, the same fold the engine uses).
    static func make(days: [DailyMetric], dayKey: String, restByDay: [String: Double]) -> [RecoveryInput] {
        let row = days.first { $0.day == dayKey }
        let hist = Array(days.filter { $0.day < dayKey }.suffix(60))
        func fold(_ values: [Double?], _ cfg: MetricCfg) -> (Double?, Int) {
            let s = Baselines.foldHistory(values, cfg: cfg)
            return (s.nValid >= 3 ? s.baseline : nil, s.nValid)
        }
        let hrv = fold(hist.map(\.avgHrv), Baselines.hrvCfg)
        let rhr = fold(hist.map { $0.restingHr.map(Double.init) }, Baselines.restingHRCfg)
        let resp = fold(hist.map(\.respRateBpm), Baselines.respCfg)
        let restHist = hist.compactMap { restByDay[$0.day] }
        let restBase: Double? = restHist.count >= 3 ? restHist.reduce(0, +) / Double(restHist.count) : nil
        return [
            RecoveryInput(id: .hrv, title: "HRV", value: row?.avgHrv, baseline: hrv.0, nights: hrv.1, unit: .ms, lowerIsBetter: false),
            RecoveryInput(id: .rhr, title: "Resting HR", value: row?.restingHr.map(Double.init), baseline: rhr.0, nights: rhr.1, unit: .bpm, lowerIsBetter: true),
            RecoveryInput(id: .respRate, title: "Respiration", value: row?.respRateBpm, baseline: resp.0, nights: resp.1, unit: .rpm, lowerIsBetter: false),
            RecoveryInput(id: .sleepPerformance, title: "Sleep performance", value: restByDay[dayKey], baseline: restBase, nights: restHist.count, unit: .percent, lowerIsBetter: false),
        ]
    }
}

/// Minutes per heart-rate zone for a day, from one-minute bucket means (a display breakdown, not the
/// engine's strain integral; the view labels it as such).
struct ZoneMinutes: Equatable {
    /// Index 0 = below zone 1, then zones 1…n in `zoneSet` order.
    let minutes: [Double]
    let zoneSet: HRZoneSet

    static func make(points: [VPoint], bucketSeconds: Int, zoneSet: HRZoneSet) -> ZoneMinutes {
        var mins = Array(repeating: 0.0, count: zoneSet.zones.count + 1)
        let step = Double(max(1, bucketSeconds)) / 60
        for p in points {
            if let i = zoneSet.zones.firstIndex(where: { p.value >= $0.lower && p.value < $0.upper }) {
                mins[i + 1] += step
            } else if let last = zoneSet.zones.last, p.value >= last.upper {
                mins[zoneSet.zones.count] += step
            } else {
                mins[0] += step
            }
        }
        return ZoneMinutes(minutes: mins, zoneSet: zoneSet)
    }
}
