import Charts
import StrandAnalytics
import SwiftUI
import WhoopStore

/// Last night in detail: hypnogram (when the night was staged on-device), stage totals, and the
/// overnight heart rate trace.
struct SleepScreen: View {
    @EnvironmentObject private var model: VitalModel

    private var d: VitalDerived { model.derived }
    private var night: CachedSleepSession? { d.lastNight }

    var body: some View {
        VScreen(title: "Sleep") {
            if let coach = d.sleepCoach { coachCard(coach) }
            if let night {
                NavigationLink { NightDetailView(night: night) } label: { headline(night) }
                    .buttonStyle(.vPress)
                timelineCard(night)
                overnightHRCard
                nightsCard
            } else {
                VCard {
                    VEmpty(systemImage: "moon.zzz",
                           title: "No sleep in the last 24 hours",
                           message: d.hasHistory
                               ? "Last night's session appears after the strap offloads and the night is staged."
                               : "Wear the strap overnight, or import a WHOOP export in Settings.")
                }
                if d.hasHistory { nightsCard }
            }
            if d.hasHistory { allNightsLink }
            VAsOf(dayKey: d.anchor?.day, computedAt: d.computedAt).padding(.top, VSpace.xs)
        }
        .toolbar { SettingsToolbarButton() }
    }

    // MARK: Cards

    /// Sleep coach: need (NOOP's personalised need), debt (NOOP's ledger), and tonight's bedtime.
    private func coachCard(_ c: SleepCoach) -> some View {
        VCard {
            VStack(alignment: .leading, spacing: VSpace.md) {
                VCardHeader(title: "Sleep coach", subtitle: "\(c.nightsUsed) nights", tint: VColor.sleep, systemImage: "bed.double.fill")
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("In bed by").font(VFont.label).foregroundStyle(VColor.textTertiary)
                        Text(c.bedtimeMin.map(SleepCoach.clock) ?? "--").font(VFont.display).monospacedDigit()
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 6) {
                        HStack(spacing: 4) {
                            Text("Need").font(VFont.label).foregroundStyle(VColor.textTertiary)
                            Text(VFormat.hoursMinutes(c.needHours * 60)).font(.subheadline.weight(.semibold)).monospacedDigit()
                        }
                        HStack(spacing: 4) {
                            Text(c.debtMin > 0 ? "Debt" : "Surplus").font(VFont.label).foregroundStyle(VColor.textTertiary)
                            Text(VFormat.hoursMinutes(abs(c.debtMin))).font(.subheadline.weight(.semibold)).monospacedDigit()
                                .foregroundStyle(c.debtMin > 60 ? VColor.recoveryMid : VColor.textPrimary)
                        }
                        if let w = c.habitualWakeMin {
                            HStack(spacing: 4) {
                                Text("Usual wake").font(VFont.label).foregroundStyle(VColor.textTertiary)
                                Text(SleepCoach.clock(w)).font(.subheadline.weight(.semibold)).monospacedDigit()
                            }
                        }
                    }
                }
                Text(c.debtMin > 60
                     ? "You're behind. Tonight's time adds back a third of the debt."
                     : "You're on track. Tonight's time covers your need.")
                    .font(.footnote).foregroundStyle(VColor.textSecondary)
            }
        }
    }

    private func headline(_ night: CachedSleepSession) -> some View {
        let totals = SleepStageTotals.minutes(fromStagesJSON: night.stagesJSON)
        let asleep = totals.map { $0.light + $0.deep + $0.rem } ?? d.anchor?.totalSleepMin
        return VCard(padding: VSpace.xl) {
            VStack(alignment: .leading, spacing: VSpace.md) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Last night").font(VFont.title)
                        Text("\(VFormat.clock(night.effectiveStartTs)) – \(VFormat.clock(night.endTs))")
                            .font(.footnote).foregroundStyle(VColor.textSecondary)
                    }
                    Spacer()
                    VScoreRing(title: "Sleep", value: VFormat.int(d.restScore), unit: "%",
                               progress: d.restScore.map { $0 / 100 }, tint: VColor.sleep, size: 84, lineWidth: 8)
                }
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(VFormat.hoursMinutes(asleep)).font(VFont.display).monospacedDigit()
                    Text("asleep").font(VFont.unit).foregroundStyle(VColor.textTertiary)
                    Spacer()
                    Text("in bed \(VFormat.hoursMinutes(Double(night.endTs - night.effectiveStartTs) / 60))")
                        .font(.footnote).foregroundStyle(VColor.textSecondary)
                }
                if let t = totals {
                    VStageBar(awake: t.awake, light: t.light, rem: t.rem, deep: t.deep)
                    HStack(spacing: VSpace.lg) {
                        stage("Deep", t.deep, VColor.stageDeep)
                        stage("REM", t.rem, VColor.stageRem)
                        stage("Light", t.light, VColor.stageLight)
                        stage("Awake", t.awake, VColor.stageAwake)
                    }
                }
            }
        }
    }

    private func timelineCard(_ night: CachedSleepSession) -> some View {
        let segs = AnalyticsEngine.decodeStages(night.stagesJSON)
        return VCard {
            VStack(alignment: .leading, spacing: VSpace.md) {
                VCardHeader(title: "Stages", subtitle: segs.isEmpty ? "Imported night" : "\(segs.count) segments",
                            tint: VColor.sleep, systemImage: "chart.bar.xaxis")
                if segs.isEmpty {
                    Text("This night came from a WHOOP export, which carries stage totals but not a timeline. Nights the strap offloads to this phone are staged here with a full hypnogram.")
                        .font(.footnote).foregroundStyle(VColor.textSecondary)
                } else {
                    HStack(spacing: 0) {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(["Awake", "REM", "Light", "Deep"], id: \.self) { lane in
                                Text(lane).font(.caption2).foregroundStyle(VColor.textTertiary)
                                    .frame(maxHeight: .infinity, alignment: .center)
                            }
                        }
                        .frame(width: 42)
                        VHypnogram(segments: segs.map { .init(start: $0.start, end: $0.end, stage: $0.stage) },
                                   start: night.effectiveStartTs, end: night.endTs)
                    }
                    .frame(height: 130)
                    HStack {
                        Text(VFormat.clock(night.effectiveStartTs))
                        Spacer()
                        Text(VFormat.clock(night.endTs))
                    }
                    .font(.caption2).foregroundStyle(VColor.textTertiary).padding(.leading, 42)
                }
            }
        }
    }

    private var overnightHRCard: some View {
        let series = NowScreen.bucket(d.lastNightHR, seconds: 300)
        return VCard {
            VStack(alignment: .leading, spacing: VSpace.md) {
                VCardHeader(title: "Overnight heart rate",
                            subtitle: d.lastNightHR.isEmpty ? nil : "\(d.lastNightHR.count) samples",
                            tint: VColor.heart, systemImage: "heart.fill")
                if series.count >= 2 {
                    VSparkline(values: series, tint: VColor.heart).frame(height: 110)
                    HStack {
                        metric("Lowest", VFormat.int(d.lastNightHR.map(\.bpm).min()), "bpm")
                        Spacer()
                        metric("Resting HR", VFormat.int(night?.restingHr ?? d.anchor?.restingHr), "bpm")
                        Spacer()
                        metric("HRV", VFormat.int(night?.avgHrv ?? d.anchor?.avgHrv), "ms")
                    }
                } else {
                    HStack {
                        metric("Resting HR", VFormat.int(night?.restingHr ?? d.anchor?.restingHr), "bpm")
                        Spacer()
                        metric("HRV", VFormat.int(night?.avgHrv ?? d.anchor?.avgHrv), "ms")
                        Spacer()
                        metric("Efficiency", night?.efficiency.map { "\(Int(($0 * 100).rounded()))" } ?? "--", "%")
                    }
                    Text("No per-beat trace for this night on this phone (imported nights carry summaries only).")
                        .font(.caption2).foregroundStyle(VColor.textTertiary)
                }
            }
        }
    }

    /// Fourteen nights of sleep duration, as bars.
    private var nightsCard: some View {
        let rows = d.days.suffix(14).filter { $0.totalSleepMin != nil }
        return VCard {
            VStack(alignment: .leading, spacing: VSpace.md) {
                VCardHeader(title: "Last 14 nights", subtitle: rows.isEmpty ? nil : "hours asleep",
                            tint: VColor.sleep, systemImage: "calendar")
                if rows.count >= 2 {
                    Chart(rows, id: \.day) { r in
                        BarMark(x: .value("Day", VFormat.date(fromKey: r.day) ?? Date(), unit: .day),
                                y: .value("Hours", (r.totalSleepMin ?? 0) / 60))
                            .foregroundStyle(VColor.sleep.gradient)
                            .cornerRadius(4)
                    }
                    .chartYAxis {
                        AxisMarks(position: .trailing) {
                            AxisGridLine().foregroundStyle(VColor.track)
                            AxisValueLabel().foregroundStyle(VColor.textTertiary)
                        }
                    }
                    .chartXAxis {
                        AxisMarks(values: .stride(by: .day, count: 3)) {
                            AxisValueLabel(format: .dateTime.weekday(.narrow)).foregroundStyle(VColor.textTertiary)
                        }
                    }
                    .frame(height: 140)
                    HStack {
                        metric("Average", VFormat.hoursMinutes(rows.compactMap(\.totalSleepMin).reduce(0, +) / Double(rows.count)), nil)
                        Spacer()
                        metric("Best", VFormat.hoursMinutes(rows.compactMap(\.totalSleepMin).max()), nil)
                        Spacer()
                        metric("Nights", "\(rows.count)", nil)
                    }
                } else {
                    Text("Not enough nights yet.").font(.footnote).foregroundStyle(VColor.textTertiary)
                }
            }
        }
    }

    /// Every night on record, imported and strap-staged alike.
    private var allNightsLink: some View {
        NavigationLink { NightsListScreen() } label: {
            HStack {
                Image(systemName: "list.bullet.rectangle").foregroundStyle(VColor.sleep)
                Text("All nights").font(.subheadline.weight(.semibold))
                Spacer()
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(VColor.textTertiary)
            }
            .padding(VSpace.lg)
            .background(VColor.surface, in: RoundedRectangle(cornerRadius: VSpace.cardRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: VSpace.cardRadius, style: .continuous).strokeBorder(VColor.hairline, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.vPress)
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

    private func metric(_ label: String, _ value: String, _ unit: String?) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(VFont.label).foregroundStyle(VColor.textTertiary)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value).font(VFont.statSmall).monospacedDigit()
                if let unit { Text(unit).font(VFont.unit).foregroundStyle(VColor.textTertiary) }
            }
        }
    }
}
