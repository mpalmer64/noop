import Charts
import WhoopProtocol
import StrandAnalytics
import SwiftUI
import WhoopStore

/// One night as the list shows it. `wakeKey` follows the engine's rule (the day the session ENDS on), so the
/// recovery shown beside a night is the recovery that night produced.
struct NightRow: Identifiable, Equatable {
    let session: CachedSleepSession
    let wakeKey: String
    let asleepMin: Double?
    let recovery: Double?
    /// Segments exist → the night was staged on this phone; otherwise it is an imported summary.
    let staged: Bool

    var id: Int { session.startTs }
    var inBedMin: Double { Double(session.endTs - session.effectiveStartTs) / 60 }
    var isNap: Bool { inBedMin < 180 }

    static func make(_ s: CachedSleepSession, days: [DailyMetric]) -> NightRow {
        let key = VitalDay.wakeDayKey(s)
        let totals = SleepStageTotals.minutes(fromStagesJSON: s.stagesJSON)
        let row = days.first { $0.day == key }
        let staged = !AnalyticsEngine.decodeStages(s.stagesJSON).isEmpty
        // A nap must not borrow the main night's total from the daily row.
        let asleep = totals?.asleep ?? (Double(s.endTs - s.effectiveStartTs) / 60 >= 180 ? row?.totalSleepMin : nil)
        return NightRow(session: s, wakeKey: key, asleepMin: asleep, recovery: row?.recovery, staged: staged)
    }
}

/// Every night on record, most recent first, grouped by month. Imported and strap-staged nights sit in one
/// list; the detail view tells them apart.
struct NightsListScreen: View {
    @EnvironmentObject private var model: VitalModel
    @State private var rows: [NightRow] = []
    @State private var loaded = false

    var body: some View {
        VScreen(title: "Nights") {
            syncNotice
            if rows.isEmpty && loaded {
                VCard {
                    VEmpty(systemImage: "moon.zzz", title: "No nights yet",
                           message: "Wear the strap overnight, or import a WHOOP export in Settings.")
                }
            } else {
                ForEach(months, id: \.self) { m in
                    VSectionTitle(text: m)
                    VCard(padding: VSpace.md) {
                        VStack(spacing: 0) {
                            let group = rows.filter { monthLabel($0.wakeKey) == m }
                            ForEach(group) { r in
                                NavigationLink { NightDetailView(night: r.session) } label: { row(r) }
                                    .buttonStyle(.vPress)
                                if r.id != group.last?.id { Divider().overlay(VColor.hairline) }
                            }
                        }
                    }
                }
            }
        }
        .toolbar { SettingsToolbarButton() }
        .task(id: model.metricCache.version) {
            let sessions = await model.repo.allSleepSessions(days: 400)
            rows = sessions.map { NightRow.make($0, days: model.derived.days) }
                .sorted { $0.session.endTs > $1.session.endTs }
            loaded = true
        }
    }

    private var months: [String] {
        var seen: [String] = []
        for r in rows { let m = monthLabel(r.wakeKey); if !seen.contains(m) { seen.append(m) } }
        return seen
    }

    private func monthLabel(_ key: String) -> String {
        VFormat.date(fromKey: key)?.formatted(.dateTime.month(.wide).year()) ?? key
    }

    /// Sleep sessions appear only after the offload is staged and scored. Say where we are instead of
    /// letting a fresh morning look like a missing night.
    @ViewBuilder
    private var syncNotice: some View {
        let today = VitalDay.todayKey()
        let hasToday = rows.contains { $0.wakeKey == today && !$0.isNap }
        if !hasToday, model.sync.backfilling || model.isScoring {
            notice(model.isScoring ? "Scoring last night…" : "Strap is offloading; last night appears once it is staged.",
                   systemImage: "arrow.triangle.2.circlepath")
        } else if !hasToday, model.live.connected, let last = model.sync.lastSyncedAt, Date().timeIntervalSince(last) < 6 * 3600 {
            notice("Synced \(VFormat.relative(last)); last night has not been staged yet.", systemImage: "clock")
        }
    }

    private func notice(_ text: String, systemImage: String) -> some View {
        HStack(spacing: VSpace.sm) {
            Image(systemName: systemImage).foregroundStyle(VColor.textTertiary)
            Text(text).font(.footnote).foregroundStyle(VColor.textSecondary)
        }
        .padding(VSpace.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(VColor.surface, in: RoundedRectangle(cornerRadius: VSpace.tileRadius, style: .continuous))
    }

    private func row(_ r: NightRow) -> some View {
        HStack(spacing: VSpace.md) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(VFormat.dayLabel(r.wakeKey)).font(.subheadline.weight(.semibold))
                    if r.isNap { VPill(text: "Nap", tint: VColor.textSecondary) }
                    if r.session.userEdited { Image(systemName: "pencil").font(.caption2).foregroundStyle(VColor.textTertiary).accessibilityLabel("Edited") }
                    if !r.staged { Image(systemName: "square.and.arrow.down").font(.caption2).foregroundStyle(VColor.textTertiary).accessibilityLabel("Imported") }
                }
                Text("\(VFormat.clock(r.session.effectiveStartTs)) – \(VFormat.clock(r.session.endTs)) · in bed \(VFormat.hoursMinutes(r.inBedMin))")
                    .font(.caption2).foregroundStyle(VColor.textTertiary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(VFormat.hoursMinutes(r.asleepMin)).font(VFont.statSmall).monospacedDigit()
                    .foregroundStyle(r.asleepMin == nil ? VColor.textTertiary : VColor.textPrimary)
                HStack(spacing: 6) {
                    if let e = r.session.efficiency { Text("\(Int((e * 100).rounded()))% eff").font(.caption2).foregroundStyle(VColor.textTertiary).monospacedDigit() }
                    if let rec = r.recovery, !r.isNap {
                        Text("\(Int(rec.rounded()))%").font(.caption2.weight(.semibold)).monospacedDigit().foregroundStyle(VColor.recovery(rec))
                    }
                }
            }
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(VColor.textTertiary)
        }
        .padding(.vertical, VSpace.sm)
        .contentShape(Rectangle())
    }
}

/// One night. Strap-staged nights get the hypnogram, motion track and overnight trace; imported nights get
/// the summary layout and a line saying where they came from.
struct NightDetailView: View {
    @EnvironmentObject private var model: VitalModel
    let night: CachedSleepSession
    @State private var hr: [HRSample] = []
    @State private var motion: [Double] = []
    @State private var restScore: Double?
    @State private var loaded = false

    private var wakeKey: String { VitalDay.wakeDayKey(night) }
    private var dayRow: DailyMetric? { model.derived.days.first { $0.day == wakeKey } }
    private var segments: [StageSegment] { AnalyticsEngine.decodeStages(night.stagesJSON) }
    private var staged: Bool { !segments.isEmpty }
    private var totals: SleepStageTotals.Minutes? { SleepStageTotals.minutes(fromStagesJSON: night.stagesJSON) }
    private var inBedMin: Double { Double(night.endTs - night.effectiveStartTs) / 60 }
    private var isNap: Bool { inBedMin < 180 }
    private var asleepMin: Double? { totals?.asleep ?? (isNap ? nil : dayRow?.totalSleepMin) }

    var body: some View {
        VScreen(title: isNap ? "Nap" : "Night") {
            headline
            MetricLink(id: .sleepPerformance, dayKey: wakeKey) { if staged { hypnogramCard } else { importedStagesCard } }
            vitalsCard
            if !isNap { MetricLink(id: .sleepHours, dayKey: wakeKey) { needCard } }
            MetricLink(id: .hr, dayKey: wakeKey) { overnightHRCard }
            provenance
        }
        .toolbar { SettingsToolbarButton() }
        .task(id: "\(night.startTs)|\(model.metricCache.version)") {
            hr = await model.repo.hrSamples(from: night.effectiveStartTs, to: night.endTs, limit: 60_000)
            motion = (await model.repo.sessionMotions(sessions: [night]))[night.startTs] ?? []
            restScore = isNap ? nil : await model.seriesValue(.descriptor(.sleepPerformance), day: wakeKey)
            loaded = true
        }
    }

    // MARK: Cards

    private var headline: some View {
        VCard(padding: VSpace.xl) {
            VStack(alignment: .leading, spacing: VSpace.md) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(VFormat.dayLabel(wakeKey)).font(VFont.title)
                            if night.userEdited { VPill(text: "Edited", tint: VColor.textSecondary) }
                        }
                        Text("\(VFormat.clock(night.effectiveStartTs)) – \(VFormat.clock(night.endTs))")
                            .font(.footnote).foregroundStyle(VColor.textSecondary)
                    }
                    Spacer()
                    if !isNap {
                        MetricLink(id: .sleepPerformance, dayKey: wakeKey) {
                            VScoreRing(title: "Sleep", value: VFormat.int(restScore), unit: "%",
                                       progress: restScore.map { $0 / 100 }, tint: VColor.sleep, size: 84, lineWidth: 8)
                        }
                    }
                }
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(VFormat.hoursMinutes(asleepMin)).font(VFont.display).monospacedDigit()
                        .foregroundStyle(asleepMin == nil ? VColor.textTertiary : VColor.textPrimary)
                    Text("asleep").font(VFont.unit).foregroundStyle(VColor.textTertiary)
                    Spacer()
                    Text("in bed \(VFormat.hoursMinutes(inBedMin))").font(.footnote).foregroundStyle(VColor.textSecondary)
                }
                if let t = totals {
                    VStageBar(awake: t.awake, light: t.light, rem: t.rem, deep: t.deep)
                    HStack(spacing: VSpace.lg) {
                        stage("Deep", t.deep, VColor.stageDeep)
                        stage("REM", t.rem, VColor.stageRem)
                        stage("Light", t.light, VColor.stageLight)
                        stage("Awake", t.awake, VColor.stageAwake)
                    }
                } else if let d = dayRow, !isNap, d.deepMin != nil || d.remMin != nil || d.lightMin != nil {
                    VStageBar(awake: 0, light: d.lightMin ?? 0, rem: d.remMin ?? 0, deep: d.deepMin ?? 0)
                    HStack(spacing: VSpace.lg) {
                        stage("Deep", d.deepMin ?? 0, VColor.stageDeep)
                        stage("REM", d.remMin ?? 0, VColor.stageRem)
                        stage("Light", d.lightMin ?? 0, VColor.stageLight)
                    }
                }
            }
        }
    }

    private var hypnogramCard: some View {
        VCard {
            VStack(alignment: .leading, spacing: VSpace.md) {
                VCardHeader(title: "Stages", subtitle: "\(segments.count) segments · \(disturbances) wake\(disturbances == 1 ? "" : "s")",
                            tint: VColor.sleep, systemImage: "chart.bar.xaxis")
                HStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(["Awake", "REM", "Light", "Deep"], id: \.self) { lane in
                            Text(lane).font(.caption2).foregroundStyle(VColor.textTertiary).frame(maxHeight: .infinity, alignment: .center)
                        }
                    }
                    .frame(width: 42)
                    VHypnogram(segments: segments.map { .init(start: $0.start, end: $0.end, stage: $0.stage) },
                               start: night.effectiveStartTs, end: night.endTs)
                }
                .frame(height: 130)
                if motion.count >= 2 {
                    MotionTrack(values: motion).frame(height: 28).padding(.leading, 42)
                    Text("Movement").font(VFont.label).foregroundStyle(VColor.textTertiary).padding(.leading, 42)
                }
                HStack {
                    Text(VFormat.clock(night.effectiveStartTs))
                    Spacer()
                    Text(VFormat.clock(night.endTs))
                }
                .font(.caption2).foregroundStyle(VColor.textTertiary).padding(.leading, 42)
            }
        }
    }

    /// Wake segments after sleep first began: what a person means by "how many times did I wake up".
    private var disturbances: Int {
        if let d = dayRow?.disturbances, !staged { return d }
        var asleepYet = false
        var n = 0
        for s in segments {
            let wake = s.stage == "wake" || s.stage == "awake"
            if !wake { asleepYet = true } else if asleepYet { n += 1 }
        }
        return n
    }

    private var importedStagesCard: some View {
        VCard {
            VStack(alignment: .leading, spacing: VSpace.sm) {
                VCardHeader(title: "Stages", subtitle: "summary only", tint: VColor.sleep, systemImage: "square.and.arrow.down")
                Text("This night came from a WHOOP export, which carries stage totals but no timeline or movement. Nights the strap offloads to this phone get the full hypnogram here.")
                    .font(.footnote).foregroundStyle(VColor.textSecondary)
                if let d = dayRow?.disturbances, !isNap {
                    Text("\(d) disturbance\(d == 1 ? "" : "s") recorded").font(.caption2).foregroundStyle(VColor.textTertiary)
                }
            }
        }
    }

    private var vitalsCard: some View {
        HStack(spacing: VSpace.md) {
            MetricLink(id: .rhr, dayKey: wakeKey) {
                VStatTile(title: "Resting HR", value: VFormat.int(night.restingHr ?? dayRow?.restingHr), unit: "bpm",
                          tint: VColor.rhr, systemImage: "heart.fill", footnote: "Lowest sustained")
            }
            MetricLink(id: .hrv, dayKey: wakeKey) {
                VStatTile(title: "HRV", value: VFormat.int(night.avgHrv ?? dayRow?.avgHrv), unit: "ms",
                          tint: VColor.hrv, systemImage: "waveform.path", footnote: "RMSSD")
            }
            VStatTile(title: "Efficiency", value: night.efficiency.map { "\(Int(($0 * 100).rounded()))" } ?? "--", unit: "%",
                      tint: VColor.sleep, systemImage: "percent", footnote: "asleep ÷ in bed")
        }
    }

    private var needCard: some View {
        let need = model.derived.sleepCoach?.needHours
        let got = asleepMin.map { $0 / 60 }
        return VCard {
            VStack(alignment: .leading, spacing: VSpace.md) {
                VCardHeader(title: "Need vs achieved", subtitle: need == nil ? "needs 3 scored nights" : nil, tint: VColor.sleep, systemImage: "bed.double.fill")
                if let need, let got {
                    HStack(alignment: .firstTextBaseline) {
                        Text(VFormat.hoursMinutes(got * 60)).font(VFont.statSmall).monospacedDigit()
                        Text("of \(VFormat.hoursMinutes(need * 60)) needed").font(.footnote).foregroundStyle(VColor.textSecondary)
                        Spacer()
                        let diff = (got - need) * 60
                        Text((diff >= 0 ? "+" : "−") + VFormat.hoursMinutes(abs(diff)))
                            .font(.footnote.weight(.semibold)).monospacedDigit()
                            .foregroundStyle(diff >= -30 ? VColor.recoveryHigh : VColor.recoveryMid)
                    }
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(VColor.track).frame(height: 8)
                            Capsule().fill(VColor.sleep).frame(width: max(4, geo.size.width * CGFloat(min(1, got / need))), height: 8)
                        }
                    }
                    .frame(height: 8)
                    Text("Need is your current personalised need (recent nights and age); the coach on the Sleep tab carries the running debt.")
                        .font(.caption2).foregroundStyle(VColor.textTertiary)
                } else {
                    Text("Need is personalised from your recent nights and age.").font(.footnote).foregroundStyle(VColor.textSecondary)
                }
            }
        }
    }

    private var overnightHRCard: some View {
        let series = MetricSeriesBuilder.bucketMeans(hr, seconds: 300)
        return VCard {
            VStack(alignment: .leading, spacing: VSpace.md) {
                VCardHeader(title: "Overnight heart rate", subtitle: hr.isEmpty ? nil : "\(hr.count) samples", tint: VColor.heart, systemImage: "heart.fill")
                if series.count >= 2 {
                    VSparkline(values: series, tint: VColor.heart).frame(height: 100)
                    HStack {
                        small("Lowest", VFormat.int(hr.map(\.bpm).min()), "bpm")
                        Spacer()
                        small("Highest", VFormat.int(hr.map(\.bpm).max()), "bpm")
                        Spacer()
                        small("Mean", VFormat.int(hr.isEmpty ? nil : Double(hr.map(\.bpm).reduce(0, +)) / Double(hr.count)), "bpm")
                    }
                } else if loaded {
                    Text("No per-beat trace for this night on this phone.").font(.footnote).foregroundStyle(VColor.textSecondary)
                } else {
                    ProgressView().frame(maxWidth: .infinity)
                }
            }
        }
    }

    private var provenance: some View {
        HStack(spacing: VSpace.sm) {
            Image(systemName: staged ? "iphone.radiowaves.left.and.right" : "square.and.arrow.down").foregroundStyle(VColor.textTertiary)
            Text(staged ? "Staged on this phone from the strap's overnight offload." : "Imported from a WHOOP export.")
                .font(.caption2).foregroundStyle(VColor.textTertiary)
            Spacer()
        }
    }

    private func stage(_ name: String, _ minutes: Double, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                Circle().fill(color).frame(width: 7, height: 7)
                Text(name).font(VFont.label).foregroundStyle(VColor.textSecondary)
            }
            Text(VFormat.hoursMinutes(minutes)).font(.subheadline.weight(.semibold)).monospacedDigit()
        }
    }

    private func small(_ label: String, _ value: String, _ unit: String?) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(VFont.label).foregroundStyle(VColor.textTertiary)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value).font(VFont.statSmall).monospacedDigit()
                if let unit { Text(unit).font(VFont.unit).foregroundStyle(VColor.textTertiary) }
            }
        }
    }
}

/// Per-epoch movement laid along the hypnogram's timeline. Bars scale to the night's own peak.
struct MotionTrack: View {
    let values: [Double]

    var body: some View {
        Canvas { ctx, size in
            let peak = max(values.max() ?? 1, 0.0001)
            let w = size.width / CGFloat(values.count)
            for (i, v) in values.enumerated() {
                let h = max(1, CGFloat(v / peak) * size.height)
                let rect = CGRect(x: CGFloat(i) * w, y: size.height - h, width: max(1, w - 0.5), height: h)
                ctx.fill(Path(rect), with: .color(VColor.stageAwake.opacity(0.75)))
            }
        }
        .accessibilityLabel("Movement through the night")
    }
}
