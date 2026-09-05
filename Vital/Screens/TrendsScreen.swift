import Charts
import SwiftUI
import WhoopStore

/// 7 / 30 / 90-day series for recovery, HRV, resting HR, strain and sleep, with period averages and the
/// change against the previous period of the same length.
struct TrendsScreen: View {
    @EnvironmentObject private var model: VitalModel
    @State private var range: TrendRange = .thirty

    enum TrendRange: Int, CaseIterable, Identifiable {
        case seven = 7, thirty = 30, ninety = 90
        var id: Int { rawValue }
        var label: String { "\(rawValue)D" }
    }

    private var days: [DailyMetric] { model.derived.days }

    var body: some View {
        VScreen(title: "Trends") {
            Picker("Range", selection: $range) {
                ForEach(TrendRange.allCases) { r in Text(r.label).tag(r) }
            }
            .pickerStyle(.segmented)
            if let last = days.map(\.day).max(), let d = VFormat.date(fromKey: last), !Calendar.current.isDateInToday(d) {
                Text("Ranges end at the latest scored day, \(VFormat.dayLabel(last)).")
                    .font(.caption).foregroundStyle(VColor.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if days.isEmpty {
                VCard {
                    VEmpty(systemImage: "chart.xyaxis.line", title: "No history yet",
                           message: "Trends fill in as days are scored or imported.")
                }
            } else {
                MetricLink(id: .recovery) {
                    trendCard("Recovery", unit: "%", tint: VColor.recoveryHigh, domain: 0...100,
                              values: series(\.recovery), colorByBand: true)
                }
                MetricLink(id: .hrv) { trendCard("HRV", unit: "ms", tint: VColor.hrv, values: series(\.avgHrv)) }
                MetricLink(id: .rhr) {
                    trendCard("Resting heart rate", unit: "bpm", tint: VColor.rhr,
                              values: series { $0.restingHr.map(Double.init) })
                }
                MetricLink(id: .strain) {
                    trendCard("Strain", unit: "", tint: VColor.strain, domain: 0...21,
                              values: series { $0.strain.map { $0 * 21 / 100 } }, decimals: 1)
                }
                MetricLink(id: .sleepHours) {
                    trendCard("Sleep", unit: "h", tint: VColor.sleep,
                              values: series { $0.totalSleepMin.map { $0 / 60 } }, decimals: 1, bars: true)
                }
            }
            VAsOf(dayKey: model.derived.anchor?.day, computedAt: model.derived.computedAt).padding(.top, VSpace.xs)
        }
        .toolbar { FriendsToolbarButton(); SettingsToolbarButton() }
    }

    // MARK: Data shaping

    struct Point: Identifiable {
        let id: String
        let date: Date
        let value: Double
    }

    private func series(_ pick: (DailyMetric) -> Double?) -> (current: [Point], previous: [Point]) {
        let n = range.rawValue
        let sorted = days.sorted { $0.day < $1.day }
        func points(_ slice: ArraySlice<DailyMetric>) -> [Point] {
            slice.compactMap { d in
                guard let v = pick(d), let date = VFormat.date(fromKey: d.day) else { return nil }
                return Point(id: d.day, date: date, value: v)
            }
        }
        let current = points(sorted.suffix(n))
        let prevEnd = max(0, sorted.count - n)
        let previous = points(sorted[max(0, prevEnd - n)..<prevEnd])
        return (current, previous)
    }

    // MARK: Card

    private func trendCard(_ title: String, unit: String, tint: Color, domain: ClosedRange<Double>? = nil,
                           values: (current: [Point], previous: [Point]), colorByBand: Bool = false,
                           decimals: Int = 0, bars: Bool = false) -> some View {
        let cur = values.current
        let avg = mean(cur.map(\.value))
        let prevAvg = mean(values.previous.map(\.value))
        let delta: Double? = (avg != nil && prevAvg != nil) ? avg! - prevAvg! : nil
        return VCard {
            VStack(alignment: .leading, spacing: VSpace.md) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).font(VFont.cardTitle).foregroundStyle(VColor.textSecondary)
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text(fmt(avg, decimals)).font(VFont.display).monospacedDigit()
                                .foregroundStyle(avg == nil ? VColor.textTertiary : VColor.textPrimary)
                            if !unit.isEmpty { Text(unit).font(VFont.unit).foregroundStyle(VColor.textTertiary) }
                            Text("avg").font(VFont.label).foregroundStyle(VColor.textTertiary)
                        }
                    }
                    Spacer()
                    if let delta {
                        deltaPill(delta, decimals: decimals, tint: tint, unit: unit)
                    }
                }
                if cur.count >= 2 {
                    chart(cur, tint: tint, domain: domain, colorByBand: colorByBand, bars: bars)
                        .frame(height: 150)
                    HStack {
                        small("Low", fmt(cur.map(\.value).min(), decimals))
                        Spacer()
                        small("High", fmt(cur.map(\.value).max(), decimals))
                        Spacer()
                        small("Days", "\(cur.count) of \(range.rawValue)")
                    }
                } else {
                    Text("Not enough days in this range.").font(.footnote).foregroundStyle(VColor.textTertiary)
                }
            }
        }
    }

    @ViewBuilder
    private func chart(_ pts: [Point], tint: Color, domain: ClosedRange<Double>?, colorByBand: Bool, bars: Bool) -> some View {
        let lo = domain?.lowerBound ?? ((pts.map(\.value).min() ?? 0) * 0.92)
        let hi = domain?.upperBound ?? ((pts.map(\.value).max() ?? 1) * 1.06)
        Chart(pts) { p in
            if bars {
                BarMark(x: .value("Day", p.date, unit: .day), y: .value("v", p.value))
                    .foregroundStyle(tint.gradient).cornerRadius(3)
            } else {
                AreaMark(x: .value("Day", p.date), yStart: .value("lo", lo), yEnd: .value("v", p.value))
                    .foregroundStyle(LinearGradient(colors: [tint.opacity(0.25), tint.opacity(0)],
                                                    startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.monotone)
                LineMark(x: .value("Day", p.date), y: .value("v", p.value))
                    .foregroundStyle(tint)
                    .lineStyle(StrokeStyle(lineWidth: 2.2, lineCap: .round))
                    .interpolationMethod(.monotone)
                if colorByBand {
                    PointMark(x: .value("Day", p.date), y: .value("v", p.value))
                        .foregroundStyle(VColor.recovery(p.value))
                        .symbolSize(range == .seven ? 40 : (range == .thirty ? 18 : 8))
                }
            }
        }
        .chartYScale(domain: lo...hi)
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) {
                AxisGridLine().foregroundStyle(VColor.track)
                AxisValueLabel().foregroundStyle(VColor.textTertiary).font(.caption2)
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) {
                AxisValueLabel(format: range == .seven ? .dateTime.weekday(.abbreviated) : .dateTime.month(.abbreviated).day())
                    .foregroundStyle(VColor.textTertiary).font(.caption2)
            }
        }
    }

    private func deltaPill(_ delta: Double, decimals: Int, tint: Color, unit: String) -> some View {
        let up = delta >= 0
        return HStack(spacing: 3) {
            Image(systemName: up ? "arrow.up.right" : "arrow.down.right").font(.caption2.weight(.bold))
            Text((up ? "+" : "") + fmt(delta, decimals) + (unit.isEmpty ? "" : " \(unit)"))
                .font(.caption.weight(.semibold)).monospacedDigit()
        }
        .foregroundStyle(tint)
        .padding(.horizontal, VSpace.sm).padding(.vertical, VSpace.xs)
        .background(tint.opacity(0.14), in: Capsule())
        .accessibilityLabel("Change versus previous \(range.rawValue) days")
    }

    private func small(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(VFont.label).foregroundStyle(VColor.textTertiary)
            Text(value).font(.subheadline.weight(.semibold)).monospacedDigit()
        }
    }

    private func mean(_ xs: [Double]) -> Double? { xs.isEmpty ? nil : xs.reduce(0, +) / Double(xs.count) }
    private func fmt(_ v: Double?, _ decimals: Int) -> String {
        guard let v else { return "--" }
        return decimals == 0 ? "\(Int(v.rounded()))" : String(format: "%.\(decimals)f", v)
    }
}
