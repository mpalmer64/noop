import Charts
import StrandAnalytics
import SwiftUI
import WhoopStore

/// Wraps any tile in a push to that metric's detail. Every drill-down in the app goes through here.
struct MetricLink<Label: View>: View {
    let id: MetricID
    var dayKey: String? = nil
    @ViewBuilder let label: () -> Label

    var body: some View {
        NavigationLink { MetricDetailView(id: id, dayKey: dayKey) } label: { label() }
            .buttonStyle(.vPress)
            .accessibilityHint("Shows history and detail")
    }
}

/// The one detail screen. Day is date-anchored and navigable; Week / Month / 6M are trailing windows ending
/// today. Daily-only metrics render the inputs that produced the score on the Day tab instead of a
/// one-point line.
struct MetricDetailView: View {
    @EnvironmentObject private var model: VitalModel
    let descriptor: VMetric
    @State private var range: TimeRange
    @State private var dayKey: String
    @State private var series: MetricSeries = .empty
    @State private var loading = true
    @State private var seriesDayValue: Double?
    /// Point under the finger while scrubbing the chart; nil when not touching.
    @State private var scrub: VPoint?

    /// `dayKey` non-nil means "open on this day": daily-only metrics land on their Day inputs.
    init(id: MetricID, dayKey: String? = nil, initialRange: TimeRange? = nil) {
        let d = VMetric.descriptor(id)
        descriptor = d
        _range = State(initialValue: initialRange ?? (dayKey == nil ? d.defaultRange : .day))
        _dayKey = State(initialValue: dayKey ?? VitalDay.todayKey())
    }

    private var d: VMetric { descriptor }
    private var today: String { VitalDay.todayKey() }
    private var dayRow: DailyMetric? { model.derived.days.first { $0.day == dayKey } }
    /// Immediate headline for a daily metric, from the already-loaded daily cache; the chart fills in after.
    private var tileValue: Double? { d.tileValue(anchor: dayRow, seriesValue: seriesDayValue) }

    var body: some View {
        VScreen(title: d.title) {
            if d.ranges.count > 1 {
                Picker("Range", selection: $range) {
                    ForEach(d.ranges) { r in Text(r.label).tag(r) }
                }
                .pickerStyle(.segmented)
            }
            if range == .day { dayNav }

            if range == .day && d.intraday == nil {
                dayInputsSection
            } else {
                // An intraday metric can still carry a nightly summary for a day with no trace (an
                // imported night's skin temperature); show it so the day is not a blank.
                if range == .day, d.dailyKey != nil, tileValue != nil { dayValueCard }
                headlineCard
            }
            if let note = d.note {
                Text(note).font(.caption2).foregroundStyle(VColor.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .toolbar { SettingsToolbarButton() }
        .task(id: "\(range.rawValue)|\(dayKey)|\(model.metricCache.version)") { await load() }
        .sensoryFeedback(.selection, trigger: range)
    }

    private func load() async {
        loading = true
        if case .series? = d.dailyKey { seriesDayValue = await model.seriesValue(d, day: dayKey) }
        series = await model.metricSeries(d, range: range, anchorKey: dayKey)
        loading = false
    }

    // MARK: Day navigation

    private var dayNav: some View {
        HStack {
            Button { step(-1) } label: { Image(systemName: "chevron.left").frame(width: 44, height: 44) }
                .accessibilityLabel("Previous day")
            Spacer()
            Text(dayTitle).font(.subheadline.weight(.semibold)).contentTransition(.numericText())
            Spacer()
            Button { step(1) } label: { Image(systemName: "chevron.right").frame(width: 44, height: 44) }
                .disabled(dayKey >= today)
                .accessibilityLabel("Next day")
        }
        .buttonStyle(.plain).foregroundStyle(VColor.textSecondary)
        .padding(.horizontal, VSpace.xs)
    }

    private var dayTitle: String {
        guard let date = VFormat.date(fromKey: dayKey) else { return dayKey }
        if Calendar.current.isDateInToday(date) { return "Today" }
        if Calendar.current.isDateInYesterday(date) { return "Yesterday" }
        return date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
    }

    private func step(_ n: Int) {
        guard let k = VitalDay.shifted(dayKey, by: n), k <= today else { return }
        withAnimation(.easeOut(duration: 0.2)) { dayKey = k }
    }

    // MARK: Headline + chart

    private var headlineCard: some View {
        let values = series.points.map(\.value)
        let agg = range == .day ? Aggregation.mean.apply(values) : d.aggregation.apply(values)
        return VCard {
            VStack(alignment: .leading, spacing: VSpace.md) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(scrub.map(scrubLabel) ?? (range == .day ? "Average" : "\(range.label) \(d.aggregation.label)"))
                            .font(VFont.label).foregroundStyle(scrub == nil ? VColor.textTertiary : d.tint)
                            .contentTransition(.numericText())
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            let shown = scrub?.value ?? agg
                            Text(d.unit.format(shown)).font(VFont.display).monospacedDigit()
                                .foregroundStyle(shown == nil ? VColor.textTertiary : d.color(for: shown))
                                .contentTransition(.numericText())
                            if !d.unit.label.isEmpty { Text(d.unit.label).font(VFont.unit).foregroundStyle(VColor.textTertiary) }
                        }
                    }
                    Spacer()
                    if loading { ProgressView().controlSize(.small) }
                    else if range != .day, series.points.count >= 4 { trendPill(values) }
                }
                if series.points.count >= 2 {
                    chart.frame(height: 190)
                    Text(range == .day ? "Touch and drag to read any moment." : "Touch and drag to read any day.")
                        .font(.caption2).foregroundStyle(VColor.textTertiary)
                    HStack {
                        stat("Low", d.unit.format(values.min()))
                        Spacer()
                        stat("High", d.unit.format(values.max()))
                        Spacer()
                        stat(range == .day ? "Readings" : "Days",
                             range == .day ? "\(series.points.count)" : "\(series.points.count) of \(series.windowDays)")
                    }
                } else if !loading {
                    VEmpty(systemImage: d.systemImage, title: emptyTitle, message: emptyMessage)
                }
            }
        }
    }

    private var emptyTitle: String { range == .day ? "Nothing recorded this day" : "Not enough days in this range" }
    private var emptyMessage: String {
        if range == .day {
            if dayKey == today, model.sync.backfilling { return "The strap is offloading now; today's readings land in a minute." }
            if dayKey == today { return "Today's readings appear after the strap syncs to this phone." }
            return "This day has no strap data on this phone. Imported WHOOP nights carry daily summaries, not the full-day trace."
        }
        if let last = model.derived.days.last?.day, last < MetricSeriesBuilder.trailingWindow(range, endKey: today).from {
            return "This window ends today, and the latest scored day is \(VFormat.dayLabel(last)). Wear the strap overnight or switch to 6M."
        }
        return "Days fill in as they are scored or imported."
    }

    /// Second half of the window against the first.
    private func trendPill(_ values: [Double]) -> some View {
        let half = values.count / 2
        let a = Aggregation.mean.apply(Array(values.prefix(half))) ?? 0
        let b = Aggregation.mean.apply(Array(values.suffix(values.count - half))) ?? 0
        let delta = b - a
        let good = d.lowerIsBetter ? delta <= 0 : delta >= 0
        let tint = good ? VColor.recoveryHigh : VColor.recoveryMid
        return HStack(spacing: 3) {
            Image(systemName: delta >= 0 ? "arrow.up.right" : "arrow.down.right").font(.caption2.weight(.bold))
            Text((delta >= 0 ? "+" : "−") + d.unit.short(abs(delta))).font(.caption.weight(.semibold)).monospacedDigit()
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(tint.opacity(0.14), in: Capsule())
        .accessibilityLabel("Second half of the range versus the first")
    }

    @ViewBuilder
    private var chart: some View {
        let pts = series.points
        let values = pts.map(\.value)
        let spread = max(1, (values.max() ?? 1) - (values.min() ?? 0))
        let lo = d.domain?.lowerBound ?? ((values.min() ?? 0) - spread * 0.12)
        let hi = d.domain?.upperBound ?? ((values.max() ?? 1) + spread * 0.08)
        let bars = d.bars && range != .day
        Chart(pts) { p in
            if bars {
                BarMark(x: .value("Day", p.date, unit: .day), y: .value("Value", p.value))
                    .foregroundStyle(d.color(for: p.value).gradient).cornerRadius(3)
            } else {
                AreaMark(x: .value("Time", p.date), yStart: .value("lo", lo), yEnd: .value("Value", p.value))
                    .foregroundStyle(LinearGradient(colors: [d.tint.opacity(0.22), d.tint.opacity(0)], startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.monotone)
                LineMark(x: .value("Time", p.date), y: .value("Value", p.value))
                    .foregroundStyle(d.tint)
                    .lineStyle(StrokeStyle(lineWidth: range == .day ? 1.6 : 2.2, lineCap: .round))
                    .interpolationMethod(.monotone)
                if range != .day, d.band(p.value) != nil {
                    PointMark(x: .value("Time", p.date), y: .value("Value", p.value))
                        .foregroundStyle(d.color(for: p.value))
                        .symbolSize(range == .week ? 40 : (range == .month ? 18 : 6))
                }
            }
        }
        .chartYScale(domain: lo...hi)
        .chartXScale(domain: xDomain)
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { g in
                                let plot = geo[proxy.plotFrame!]
                                let x = g.location.x - plot.origin.x
                                guard let date: Date = proxy.value(atX: x) else { return }
                                let target = Int(date.timeIntervalSince1970)
                                let nearest = pts.min { abs($0.ts - target) < abs($1.ts - target) }
                                if nearest != scrub { scrub = nearest }
                            }
                            .onEnded { _ in scrub = nil }
                    )
                if let scrub, let plot = Optional(geo[proxy.plotFrame!]), let px = proxy.position(forX: scrub.date) {
                    Rectangle().fill(d.tint.opacity(0.6)).frame(width: 1, height: plot.height)
                        .position(x: plot.origin.x + px, y: plot.midY)
                    if let py = proxy.position(forY: scrub.value) {
                        Circle().fill(d.tint).frame(width: 10, height: 10)
                            .overlay(Circle().stroke(VColor.surface, lineWidth: 2))
                            .position(x: plot.origin.x + px, y: plot.origin.y + py)
                    }
                }
            }
        }
        .sensoryFeedback(.selection, trigger: scrub)
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 4)) { v in
                AxisGridLine().foregroundStyle(VColor.track)
                AxisValueLabel { if let x = v.as(Double.self) { Text(d.unit.short(x)) } }
                    .foregroundStyle(VColor.textTertiary).font(.caption2)
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: range == .day ? 5 : 4)) {
                AxisValueLabel(format: xFormat).foregroundStyle(VColor.textTertiary).font(.caption2)
            }
        }
    }

    /// "6:42 PM" for an intraday point, "Thu, Jul 16" for a daily one.
    private func scrubLabel(_ p: VPoint) -> String {
        if range == .day {
            let end = series.bucketSeconds > 60 ? " – " + VFormat.clock(p.ts + series.bucketSeconds) : ""
            return VFormat.clock(p.ts) + end
        }
        if series.bucketSeconds > 0 && series.bucketSeconds < 86_400 {
            return p.date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour())
        }
        return VFormat.dayLabel(VitalDay.key(forTs: p.ts))
    }

    private var xDomain: ClosedRange<Date> {
        if range == .day, let w = VitalDay.window(forKey: dayKey) {
            let start = Date(timeIntervalSince1970: TimeInterval(w.lowerBound))
            let end = dayKey == today ? Date() : Date(timeIntervalSince1970: TimeInterval(w.upperBound))
            return start...max(end, start.addingTimeInterval(3600))
        }
        let (from, to) = MetricSeriesBuilder.trailingWindow(range, endKey: today)
        let a = VitalDay.date(forKey: from) ?? Date()
        let b = (VitalDay.date(forKey: to) ?? Date()).addingTimeInterval(86_400)
        return a...b
    }

    private var xFormat: Date.FormatStyle {
        switch range {
        case .day: return .dateTime.hour()
        case .week: return .dateTime.weekday(.abbreviated)
        case .month, .sixMonths: return .dateTime.month(.abbreviated).day()
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(VFont.label).foregroundStyle(VColor.textTertiary)
            Text(value).font(.subheadline.weight(.semibold)).monospacedDigit()
        }
    }

    // MARK: Day tab for daily-only metrics

    @ViewBuilder
    private var dayInputsSection: some View {
        dayValueCard
        switch d.dayInputs {
        case .recoveryInputs: RecoveryInputsCard(dayKey: dayKey)
        case .strainInputs: StrainInputsCard(dayKey: dayKey)
        case .night: NightLinkCard(wakeKey: dayKey)
        case .summary: EmptyView()
        }
    }

    private var dayValueCard: some View {
        VCard {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(d.title).font(VFont.label).foregroundStyle(VColor.textTertiary)
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(d.unit.format(tileValue)).font(VFont.display).monospacedDigit()
                            .foregroundStyle(tileValue == nil ? VColor.textTertiary : d.color(for: tileValue))
                            .contentTransition(.numericText())
                        if !d.unit.label.isEmpty { Text(d.unit.label).font(VFont.unit).foregroundStyle(VColor.textTertiary) }
                    }
                }
                Spacer()
                if tileValue == nil {
                    Text(dayKey == today ? "Not scored yet" : "No score this day")
                        .font(.footnote).foregroundStyle(VColor.textTertiary)
                } else if let v = tileValue, let b = d.band(v) {
                    VPill(text: b == .low ? "Low" : (b == .mid ? "Moderate" : "High"), tint: d.color(for: v), filled: true)
                }
            }
        }
    }
}

// MARK: - Recovery inputs

struct RecoveryInputsCard: View {
    @EnvironmentObject private var model: VitalModel
    let dayKey: String
    @State private var inputs: [RecoveryInput] = []

    var body: some View {
        VCard {
            VStack(alignment: .leading, spacing: VSpace.md) {
                VCardHeader(title: "What produced it", subtitle: "each against your baseline", tint: VColor.hrv, systemImage: "slider.horizontal.3")
                ForEach(inputs) { i in
                    MetricLink(id: i.id, dayKey: dayKey) { row(i) }
                    if i.id != inputs.last?.id { Divider().overlay(VColor.hairline) }
                }
                Text("Baselines fold the 60 scored days before this one, the same way the engine does.")
                    .font(.caption2).foregroundStyle(VColor.textTertiary)
            }
        }
        .task(id: "\(dayKey)|\(model.metricCache.version)") {
            let rest = await model.restByDay()
            inputs = RecoveryInputs.make(days: model.derived.days, dayKey: dayKey, restByDay: rest)
        }
    }

    private func row(_ i: RecoveryInput) -> some View {
        HStack(spacing: VSpace.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text(i.title).font(.subheadline.weight(.semibold))
                Text(i.baseline.map { "baseline \(i.unit.format($0))\(i.unit.label.isEmpty ? "" : " \(i.unit.label)") · \(i.nights) nights" } ?? "baseline needs 3 nights")
                    .font(.caption2).foregroundStyle(VColor.textTertiary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(i.unit.format(i.value)).font(VFont.statSmall).monospacedDigit()
                    .foregroundStyle(i.value == nil ? VColor.textTertiary : VColor.textPrimary)
                if let dev = i.deviationPct {
                    let good = i.lowerIsBetter ? dev <= 0 : dev >= 0
                    Text(String(format: "%@%.0f%%", dev >= 0 ? "+" : "−", abs(dev)))
                        .font(.caption2.weight(.semibold)).monospacedDigit()
                        .foregroundStyle(abs(dev) < 5 ? VColor.textTertiary : (good ? VColor.recoveryHigh : VColor.recoveryMid))
                }
            }
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(VColor.textTertiary)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

// MARK: - Strain inputs

struct StrainInputsCard: View {
    @EnvironmentObject private var model: VitalModel
    let dayKey: String
    @State private var hr: MetricSeries = .empty
    @State private var loading = true

    private var zoneSet: HRZoneSet { model.profile.hrZoneSet }
    private var sessions: [WorkoutRow] {
        guard let w = VitalDay.window(forKey: dayKey) else { return [] }
        return model.workouts.filter { $0.startTs >= w.lowerBound && $0.startTs <= w.upperBound }.sorted { $0.startTs < $1.startTs }
    }

    var body: some View {
        VCard {
            VStack(alignment: .leading, spacing: VSpace.md) {
                VCardHeader(title: "Heart rate through the day", subtitle: hr.points.isEmpty ? nil : "zones shaded", tint: VColor.heart, systemImage: "heart.fill")
                if hr.points.count >= 2 {
                    zoneChart.frame(height: 170)
                    let zm = ZoneMinutes.make(points: hr.points, bucketSeconds: hr.bucketSeconds, zoneSet: zoneSet)
                    ZoneBar(seconds: zoneSeconds(zm))
                    Text("Zone minutes from \(hr.bucketSeconds >= 60 ? "\(hr.bucketSeconds / 60)-minute" : "per-second") averages; the score itself integrates every beat.")
                        .font(.caption2).foregroundStyle(VColor.textTertiary)
                } else if !loading {
                    Text(dayKey == VitalDay.todayKey() ? "Today's trace lands after the strap syncs." : "No full-day heart-rate trace for this day on this phone.")
                        .font(.footnote).foregroundStyle(VColor.textSecondary)
                } else {
                    ProgressView().frame(maxWidth: .infinity)
                }
                if !sessions.isEmpty {
                    Divider().overlay(VColor.hairline)
                    Text("Sessions").font(VFont.label).foregroundStyle(VColor.textTertiary)
                    ForEach(sessions, id: \.startTs) { w in
                        HStack {
                            Image(systemName: ActivityIcon.symbol(for: w.sport)).foregroundStyle(VColor.strain).frame(width: 22)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(w.sport).font(.subheadline.weight(.semibold))
                                Text("\(VFormat.clock(w.startTs)) · \(VFormat.hoursMinutes(Double(w.endTs - w.startTs) / 60))").font(.caption2).foregroundStyle(VColor.textTertiary)
                            }
                            Spacer()
                            Text(VFormat.whoopStrain(w.strain)).font(VFont.statSmall).monospacedDigit()
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
        .task(id: "\(dayKey)|\(model.metricCache.version)") {
            loading = true
            hr = await model.metricSeries(.descriptor(.hr), range: .day, anchorKey: dayKey)
            loading = false
        }
    }

    /// `ZoneBar` wants exactly five zone buckets in seconds; pad or trim the profile's zone count to fit.
    private func zoneSeconds(_ zm: ZoneMinutes) -> [Double] {
        var z = Array(zm.minutes.dropFirst()).map { $0 * 60 }
        while z.count < 5 { z.append(0) }
        return Array(z.prefix(5))
    }

    private var zoneChart: some View {
        let pts = hr.points
        let maxV = max(pts.map(\.value).max() ?? 100, zoneSet.zones.first?.upper ?? 100) + 5
        let minV = max(30, (pts.map(\.value).min() ?? 40) - 10)
        return Chart {
            ForEach(Array(zoneSet.zones.enumerated()), id: \.offset) { i, z in
                RectangleMark(yStart: .value("lo", max(minV, z.lower)), yEnd: .value("hi", min(maxV, z.upper)))
                    .foregroundStyle(zoneColor(i + 1).opacity(0.10))
            }
            ForEach(pts) { p in
                LineMark(x: .value("Time", p.date), y: .value("bpm", p.value))
                    .foregroundStyle(VColor.heart).lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round))
                    .interpolationMethod(.monotone)
            }
        }
        .chartYScale(domain: minV...maxV)
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 4)) {
                AxisGridLine().foregroundStyle(VColor.track)
                AxisValueLabel().foregroundStyle(VColor.textTertiary).font(.caption2)
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 5)) {
                AxisValueLabel(format: .dateTime.hour()).foregroundStyle(VColor.textTertiary).font(.caption2)
            }
        }
    }
}

// MARK: - Night link

struct NightLinkCard: View {
    @EnvironmentObject private var model: VitalModel
    let wakeKey: String
    @State private var night: CachedSleepSession?
    @State private var loaded = false

    var body: some View {
        VCard {
            VStack(alignment: .leading, spacing: VSpace.md) {
                VCardHeader(title: "The night behind it", tint: VColor.sleep, systemImage: "moon.zzz.fill")
                if let night {
                    NavigationLink { NightDetailView(night: night) } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(VFormat.clock(night.effectiveStartTs)) – \(VFormat.clock(night.endTs))").font(.subheadline.weight(.semibold))
                                Text("in bed \(VFormat.hoursMinutes(Double(night.endTs - night.effectiveStartTs) / 60))").font(.caption2).foregroundStyle(VColor.textTertiary)
                            }
                            Spacer()
                            Text("Open night").font(.footnote.weight(.semibold)).foregroundStyle(VColor.sleep)
                            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(VColor.textTertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.vPress)
                } else if loaded {
                    Text(wakeKey == VitalDay.todayKey() && model.sync.backfilling
                         ? "The strap is offloading; last night appears once it is staged."
                         : "No sleep session ends on this day.")
                        .font(.footnote).foregroundStyle(VColor.textSecondary)
                } else {
                    ProgressView().frame(maxWidth: .infinity)
                }
            }
        }
        .task(id: "\(wakeKey)|\(model.metricCache.version)") {
            night = await model.night(forWakeDay: wakeKey)
            loaded = true
        }
    }
}
