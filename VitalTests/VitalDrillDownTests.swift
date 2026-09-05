import XCTest
import WhoopStore
@testable import Vital

/// Pure tests for the drill-down data layer: day windows, wake-day attribution, and the tile/series
/// agreement contract. No store, no strap.
final class VitalDrillDownTests: XCTestCase {

    // MARK: Day window

    func testWindowRoundTripsEveryEdge() {
        for tz in [-5 * 3600, 0, 3600, 9 * 3600 + 1800] {
            let key = "2026-03-14"
            guard let w = VitalDay.window(forKey: key, tzOffset: tz) else { return XCTFail("window nil for tz \(tz)") }
            XCTAssertEqual(w.upperBound - w.lowerBound, 86_399)
            XCTAssertEqual(VitalDay.key(forTs: w.lowerBound, tzOffset: tz), key, "tz \(tz) start")
            XCTAssertEqual(VitalDay.key(forTs: w.upperBound, tzOffset: tz), key, "tz \(tz) end")
            XCTAssertEqual(VitalDay.key(forTs: w.lowerBound - 1, tzOffset: tz), "2026-03-13", "tz \(tz) before")
            XCTAssertEqual(VitalDay.key(forTs: w.upperBound + 1, tzOffset: tz), "2026-03-15", "tz \(tz) after")
        }
    }

    func testShiftAndDistance() {
        XCTAssertEqual(VitalDay.shifted("2026-03-01", by: -1), "2026-02-28")
        XCTAssertEqual(VitalDay.shifted("2026-12-31", by: 1), "2027-01-01")
        XCTAssertEqual(VitalDay.distance(from: "2026-01-01", to: "2026-01-08"), 7)
        XCTAssertNil(VitalDay.window(forKey: "not-a-day"))
    }

    /// A night is filed under the day it ends on, in the scoring timezone, even when it starts the day before.
    func testWakeDayKeyUsesEndTimestamp() {
        let tz = -4 * 3600
        let w = VitalDay.window(forKey: "2026-03-14", tzOffset: tz)!
        let night = CachedSleepSession(startTs: w.lowerBound - 3 * 3600, endTs: w.lowerBound + 7 * 3600,
                                       efficiency: 0.9, restingHr: 50, avgHrv: 70, stagesJSON: nil)
        XCTAssertEqual(VitalDay.wakeDayKey(night, tzOffset: tz), "2026-03-14")
        let early = CachedSleepSession(startTs: w.lowerBound - 8 * 3600, endTs: w.lowerBound - 1,
                                       efficiency: nil, restingHr: nil, avgHrv: nil, stagesJSON: nil)
        XCTAssertEqual(VitalDay.wakeDayKey(early, tzOffset: tz), "2026-03-13")
    }

    // MARK: Tile ⇔ series agreement

    private func day(_ key: String, recovery: Double?, hrv: Double?, rhr: Int?, strain: Double?, sleepMin: Double?, steps: Int? = nil) -> DailyMetric {
        DailyMetric(day: key, totalSleepMin: sleepMin, efficiency: nil, deepMin: nil, remMin: nil, lightMin: nil,
                    disturbances: nil, restingHr: rhr, avgHrv: hrv, recovery: recovery, strain: strain,
                    exerciseCount: nil, steps: steps)
    }

    private var fixture: [DailyMetric] {
        [
            day("2026-03-08", recovery: 40, hrv: 55, rhr: 58, strain: 30, sleepMin: 400),
            day("2026-03-09", recovery: 61, hrv: 62, rhr: 55, strain: 52, sleepMin: 430),
            day("2026-03-10", recovery: nil, hrv: nil, rhr: nil, strain: 12, sleepMin: nil),   // partial day
            day("2026-03-11", recovery: 88, hrv: 81, rhr: 51, strain: 71, sleepMin: 470, steps: 9000),
            day("2026-03-12", recovery: 72, hrv: 70, rhr: 53, strain: 44, sleepMin: 450),
            day("2026-03-14", recovery: 96, hrv: 71, rhr: 51, strain: 34.3, sleepMin: 480, steps: 4200),
        ]
    }

    /// The contract the spec asks for: for every daily column metric, the anchor day's tile value is the last
    /// point of that metric's own Week series ending on the anchor.
    func testTileValueEqualsLastPointOfWeekSeries() {
        let anchor = fixture.last!
        let (from, to) = MetricSeriesBuilder.trailingWindow(.week, endKey: anchor.day)
        XCTAssertEqual(from, "2026-03-08")
        let anchorTs = VitalDay.window(forKey: anchor.day, tzOffset: 0)?.lowerBound
        for id in MetricID.allCases {
            let d = VMetric.descriptor(id)
            guard case .column? = d.dailyKey else { continue }
            let series = MetricSeriesBuilder.daily(d, days: fixture, seriesByDay: [:], from: from, to: to, tzOffset: 0)
            if let tile = d.tileValue(anchor: anchor, seriesValue: nil) {
                XCTAssertEqual(series.last?.value ?? .nan, tile, accuracy: 1e-9, "\(id) tile vs week-last")
                XCTAssertEqual(series.last?.ts, anchorTs, "\(id) last point sits on the anchor day")
            } else {
                XCTAssertNotEqual(series.last?.ts, anchorTs, "\(id) has no anchor value so the series must not end on it")
            }
        }
    }

    func testSeriesKeyMetricUsesResolvedSeriesValue() {
        let d = VMetric.descriptor(.sleepPerformance)
        let rest = ["2026-03-12": 81.0, "2026-03-14": 94.0, "2026-03-20": 50.0]   // one point past the window
        let (from, to) = MetricSeriesBuilder.trailingWindow(.week, endKey: "2026-03-14")
        let series = MetricSeriesBuilder.daily(d, days: [], seriesByDay: rest, from: from, to: to, tzOffset: 0)
        XCTAssertEqual(series.map(\.value), [81, 94])
        XCTAssertEqual(d.tileValue(anchor: fixture.last, seriesValue: rest["2026-03-14"]), series.last?.value)
    }

    func testWeekSeriesSkipsDaysWithoutAValueAndStaysSorted() {
        let d = VMetric.descriptor(.recovery)
        let s = MetricSeriesBuilder.daily(d, days: Array(fixture.reversed()), seriesByDay: [:],
                                          from: "2026-03-08", to: "2026-03-14", tzOffset: 0)
        XCTAssertEqual(s.map(\.value), [40, 61, 88, 72, 96])
        XCTAssertEqual(s.map(\.ts), s.map(\.ts).sorted())
    }

    func testStrainColumnIsOnWhoopScale() {
        let d = VMetric.descriptor(.strain)
        XCTAssertEqual(d.tileValue(anchor: fixture[1], seriesValue: nil)!, 52 * 21 / 100, accuracy: 1e-9)
    }

    // MARK: Descriptor registry

    func testEveryMetricHasADescriptorAndAtLeastOneRange() {
        XCTAssertEqual(VMetric.all.count, MetricID.allCases.count)
        for d in VMetric.all {
            XCTAssertFalse(d.ranges.isEmpty, "\(d.id)")
            XCTAssertTrue(d.ranges.contains(d.defaultRange), "\(d.id) default range must be offered")
            if d.intraday == nil { XCTAssertNotEqual(d.defaultRange, .day, "\(d.id) daily-only metrics open on a trailing range") }
        }
    }

    // MARK: Downsampling

    func testDownsampleKeepsMeansAndOrder() {
        let pts = (0..<1000).map { VPoint(ts: 1_700_000_000 + $0 * 10, value: Double($0 % 2 == 0 ? 60 : 80)) }
        let out = MetricSeriesBuilder.downsample(pts, target: 100)
        XCTAssertLessThanOrEqual(out.count, 101)
        XCTAssertGreaterThanOrEqual(out.count, 99)
        // Buckets hold 9–11 alternating samples, so each mean sits between the two levels and the whole
        // series still averages to the source mean.
        for p in out { XCTAssertTrue((60...80).contains(p.value), "\(p.value)") }
        XCTAssertEqual(out.map(\.value).reduce(0, +) / Double(out.count), 70, accuracy: 0.5)
        XCTAssertEqual(out.map(\.ts), out.map(\.ts).sorted())
        XCTAssertEqual(MetricSeriesBuilder.downsample(Array(pts.prefix(50)), target: 100).count, 50, "small series pass through")
    }

    func testHrBucketWidthsKeepWindowsSmall() {
        for r in TimeRange.allCases where r != .day {
            let points = r.days * 86_400 / MetricSeriesBuilder.hrBucketSeconds(r)
            XCTAssertLessThanOrEqual(points, 190, "\(r)")
        }
    }
}
