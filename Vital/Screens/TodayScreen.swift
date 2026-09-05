import SwiftUI
import WhoopProtocol
import WhoopStore

/// Scored day: recovery, strain, sleep performance, and the vitals behind them. Everything here is
/// derived from offloaded history and carries the day it describes.
struct TodayScreen: View {
    @EnvironmentObject private var model: VitalModel
    @ObservedObject private var live: LiveState
    /// Debug: `VITAL_TAB=friends` pushes the leaderboard from Today (a read, so a push, never a sheet).
    @State private var friendsPushed = ProcessInfo.processInfo.environment["VITAL_TAB"] == "friends"
    /// Debug: `VITAL_TAB=browse` pushes the all-metrics list from Today.
    @State private var browsePushed = ProcessInfo.processInfo.environment["VITAL_TAB"] == "browse"

    init(live: LiveState) { self.live = live }

    private var d: VitalDerived { model.derived }
    private var day: DailyMetric? { d.anchor }

    /// The live strip's inputs, gathered from the model (smoothed bpm, sync) and the BLE state.
    private var stripState: LiveStripState {
        LiveStripState(bpm: model.bpm,
                       connected: live.connected,
                       bonded: live.bonded,
                       backfilling: live.backfilling,
                       batteryPct: live.batteryPct,
                       charging: live.charging == true,
                       modelLabel: live.connected ? (live.whoop5Variant ?? (model.isWhoop5 ? "WHOOP 5.0" : "WHOOP 4.0")) : nil,
                       lastSynced: model.sync.lastSyncedAt,
                       hint: live.pairingHint ?? live.reconnectGuide,
                       error: live.lastSyncError)
    }

    var body: some View {
        VScreen(title: "Today") {
            LiveStrip(state: stripState,
                      actions: LiveStripActions(connect: { model.connect($0) }, sync: { model.syncNow() }))
            if !d.hasHistory && !model.isScoring {
                VCard {
                    VEmpty(systemImage: "sparkles",
                           title: "No scored days yet",
                           message: "Wear the strap overnight, or import a WHOOP export in Settings to seed months of history.")
                }
            } else {
                if let day, !isRecent(day.day) { staleNotice(day.day) }
                ringsCard
                if let coach = model.strainCoach {
                    MetricLink(id: .strain, dayKey: day?.day) { strainCoachCard(coach) }
                }
                vitalsGrid
                todayHRCard
                if let h = d.health { healthCard(h) }
                sleepCard
                JournalCard(dayKey: day?.day ?? VitalDay.todayKey())
                if let day, day.steps != nil || day.activeKcalEst != nil { activityCard(day) }
            }
            BrowseLinkCard()
            VAsOf(dayKey: day?.day, computedAt: d.computedAt)
                .padding(.top, VSpace.xs)
        }
        .toolbar { FriendsToolbarButton(); SettingsToolbarButton() }
        .navigationDestination(isPresented: $friendsPushed) { LeaderboardScreen() }
        .navigationDestination(isPresented: $browsePushed) { BrowseScreen() }
        .refreshable { await model.runScoring(force: false, skipIfUnchanged: true) }
        // One wanter on the model's realtime counter while Today is on screen (Activities holds its own).
        .onAppear { model.startRealtimeHR() }
        .onDisappear { model.stopRealtimeHR() }
    }

    /// Today's banked heart rate so far (10-minute means), pushing the HR Day detail.
    private var todayHRCard: some View {
        let hr = d.todayHR
        let buckets = MetricSeriesBuilder.bucketMeans(hr, seconds: 600)
        return MetricLink(id: .hr, dayKey: VitalDay.todayKey()) {
            VCard {
                VStack(alignment: .leading, spacing: VSpace.md) {
                    VCardHeader(title: "Heart rate today",
                                subtitle: buckets.isEmpty ? nil : "\(hr.count) samples",
                                tint: VColor.heart, systemImage: "waveform.path.ecg")
                    if buckets.count >= 2 {
                        VSparkline(values: buckets, tint: VColor.heart, showsLast: true).frame(height: 120)
                        HStack {
                            hrStat("Low", hr.map { Double($0.bpm) }.min())
                            Spacer()
                            hrStat("Avg", hr.isEmpty ? nil : Double(hr.map(\.bpm).reduce(0, +)) / Double(hr.count))
                            Spacer()
                            hrStat("High", hr.map { Double($0.bpm) }.max())
                        }
                    } else {
                        VEmpty(systemImage: "waveform.path.ecg",
                               title: "No heart rate banked yet today",
                               message: "The strap buffers HR and offloads it in bursts every 15–20 minutes while connected.")
                    }
                }
            }
        }
    }

    private func hrStat(_ label: String, _ v: Double?) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(VFont.label).foregroundStyle(VColor.textTertiary)
            Text(VFormat.int(v)).font(VFont.statSmall).monospacedDigit()
        }
    }

    /// WHOOP-style strain coach: where today's accrual sits against the band the recovery earns.
    private func strainCoachCard(_ coach: StrainCoach) -> some View {
        let current = (strainToShow ?? 0) * 21 / 100
        let lo = coach.targetRange.lowerBound, hi = coach.targetRange.upperBound
        return VCard {
            VStack(alignment: .leading, spacing: VSpace.md) {
                VCardHeader(title: "Strain coach", subtitle: String(format: "target %.0f–%.0f", lo, hi),
                            tint: VColor.strain, systemImage: "target")
                HStack(alignment: .firstTextBaseline) {
                    Text(coach.headline).font(VFont.title)
                    Spacer()
                    Text(current >= lo ? (current > hi ? "Over target" : "In range") : String(format: "%.1f to go", lo - current))
                        .font(.footnote.weight(.semibold)).foregroundStyle(current >= lo ? VColor.recoveryHigh : VColor.textSecondary)
                }
                GeometryReader { geo in
                    let w = geo.size.width
                    ZStack(alignment: .leading) {
                        Capsule().fill(VColor.track).frame(height: 8)
                        Capsule().fill(VColor.strain.opacity(0.35))
                            .frame(width: w * CGFloat((hi - lo) / 21), height: 8)
                            .offset(x: w * CGFloat(lo / 21))
                        Capsule().fill(VColor.strain).frame(width: max(4, w * CGFloat(min(21, current) / 21)), height: 8)
                    }
                }
                .frame(height: 8)
                Text(coach.band == .low
                     ? "Recovery is low, so light movement counts as a win today."
                     : coach.band == .mid ? "Aim for a solid session without redlining."
                     : "Your body is ready for a hard day; a big session will land well.")
                    .font(.footnote).foregroundStyle(VColor.textSecondary)
            }
        }
    }

    /// Health monitor: overnight vitals against your own recent baseline (NOOP's VitalBands).
    private func healthCard(_ h: HealthMonitor) -> some View {
        VCard {
            VStack(alignment: .leading, spacing: VSpace.sm) {
                VCardHeader(title: "Health monitor",
                            subtitle: h.outOfRange == 0 ? "All in your range" : "\(h.outOfRange) outside your range",
                            tint: h.outOfRange == 0 ? VColor.recoveryHigh : VColor.recoveryMid, systemImage: "stethoscope")
                ForEach(h.items) { item in
                    MetricLink(id: Self.healthMetric(item.id), dayKey: day?.day) {
                        HStack {
                            Circle().fill(item.band == .outOfRange ? VColor.recoveryMid : VColor.recoveryHigh).frame(width: VSpace.sm, height: VSpace.sm)
                            Text(item.title).font(.subheadline)
                            Spacer()
                            Text(item.value).font(.subheadline.weight(.semibold)).monospacedDigit()
                            Text(item.band == .outOfRange ? "outside" : "typical")
                                .font(.caption2).foregroundStyle(VColor.textTertiary).frame(width: 52, alignment: .trailing)
                            Image(systemName: "chevron.right").font(.caption2.weight(.semibold)).foregroundStyle(VColor.textTertiary)
                        }
                        .padding(.vertical, VSpace.xs)
                        .contentShape(Rectangle())
                    }
                }
                Text("Ranges come from your own last 30 nights; not a diagnosis.")
                    .font(.caption2).foregroundStyle(VColor.textTertiary)
            }
        }
    }

    // MARK: Cards

    private var ringsCard: some View {
        VCard(padding: VSpace.xl) {
            VStack(spacing: VSpace.lg) {
                HStack {
                    Text(day.map { headerLabel($0.day) } ?? "Today")
                        .font(VFont.title)
                    Spacer()
                    if model.isScoring {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Scoring").font(VFont.caption).foregroundStyle(VColor.textTertiary)
                        }
                    } else if let r = day?.recovery {
                        VPill(text: bandName(r), tint: VColor.recovery(r), filled: true)
                    }
                }
                HStack(alignment: .top) {
                    MetricLink(id: .recovery, dayKey: day?.day) {
                        VScoreRing(title: "Recovery", value: VFormat.int(day?.recovery), unit: "%",
                                   progress: day?.recovery.map { $0 / 100 }, tint: VColor.recovery(day?.recovery))
                    }
                    Spacer()
                    MetricLink(id: .strain, dayKey: day?.day) {
                        VScoreRing(title: "Strain", value: VFormat.whoopStrain(strainToShow), unit: "of 21",
                                   progress: strainToShow.map { min(1, $0 / 100) }, tint: VColor.strain)
                    }
                    Spacer()
                    MetricLink(id: .sleepPerformance, dayKey: day?.day) {
                        VScoreRing(title: "Sleep", value: VFormat.int(d.restScore), unit: "%",
                                   progress: d.restScore.map { $0 / 100 }, tint: VColor.sleep)
                    }
                }
                if let r = day?.recovery {
                    Text(recoveryLine(r))
                        .font(.footnote).foregroundStyle(VColor.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    /// Today's stored strain when the anchor is today and it exceeds the live accrual; otherwise the live
    /// value (which keeps growing as HR banks) — never show less than what already happened.
    private var strainToShow: Double? {
        let stored = day?.strain
        if let live = d.liveStrain, day?.day == Repository.localDayKey(Date()) {
            return max(live, stored ?? 0)
        }
        return stored ?? d.liveStrain
    }

    private var vitalsGrid: some View {
        let hrvSpark = d.days.suffix(14).compactMap(\.avgHrv)
        let rhrSpark = d.days.suffix(14).compactMap(\.restingHr).map(Double.init)
        return VStack(spacing: VSpace.md) {
            HStack(spacing: VSpace.md) {
                MetricLink(id: .hrv, dayKey: day?.day) {
                    VStatTile(title: "HRV", value: VFormat.int(day?.avgHrv), unit: "ms",
                              tint: VColor.hrv, systemImage: "waveform.path",
                              footnote: "Overnight RMSSD", spark: hrvSpark.count >= 2 ? hrvSpark : nil)
                }
                MetricLink(id: .rhr, dayKey: day?.day) {
                    VStatTile(title: "Resting HR", value: VFormat.int(day?.restingHr), unit: "bpm",
                              tint: VColor.rhr, systemImage: "heart.fill",
                              footnote: "Lowest sustained overnight", spark: rhrSpark.count >= 2 ? rhrSpark : nil)
                }
            }
            HStack(spacing: VSpace.md) {
                MetricLink(id: .respRate, dayKey: day?.day) { respirationTile }
                MetricLink(id: .spo2, dayKey: day?.day) { spo2Tile }
            }
            if let t = day?.skinTempDevC {
                // On-device rows store a deviation from baseline; a WHOOP export row stores the absolute
                // reading (WhoopImporter notes this). Anything above 20 cannot be a deviation.
                MetricLink(id: .skinTemp, dayKey: day?.day) {
                    if t > 20 {
                        VStatTile(title: "Skin temp", value: VitalUnits.temperature(celsius: t),
                                  tint: VColor.temperature, systemImage: "thermometer.medium",
                                  footnote: "Absolute reading from the WHOOP export")
                    } else {
                        VStatTile(title: "Skin temp", value: VitalUnits.temperatureDelta(celsius: t), unit: "vs baseline",
                                  tint: VColor.temperature, systemImage: "thermometer.medium",
                                  footnote: abs(t) < 0.3 ? "Within your normal range" : "Outside your normal range")
                    }
                }
            }
        }
    }

    /// Model-aware: a WHOOP 5.0 / MG has no respiration waveform on the wire; NOOP estimates from R-R.
    private var respirationTile: some View {
        VStatTile(title: "Respiration", value: VFormat.one(day?.respRateBpm), unit: "rpm",
                  tint: VColor.respiration, systemImage: "lungs.fill",
                  footnote: model.isWhoop5 ? "Estimated from R-R intervals" : "From the raw respiration track")
    }

    /// Model-aware: no SpO₂ channel on a 5.0 / MG — render that fact, not "no data".
    @ViewBuilder
    private var spo2Tile: some View {
        if model.isWhoop5 {
            VStatTile(title: "Blood oxygen", value: "—", tint: VColor.oxygen, systemImage: "drop.fill",
                      footnote: "Not measured by WHOOP 5.0 / MG")
        } else {
            VStatTile(title: "Blood oxygen", value: VFormat.int(day?.spo2Pct), unit: "%",
                      tint: VColor.oxygen, systemImage: "drop.fill", footnote: "Mean during sleep")
        }
    }

    /// `HealthMonitor.Item.id` → the metric its row opens.
    static func healthMetric(_ id: String) -> MetricID {
        switch id {
        case "rhr": return .rhr
        case "hrv": return .hrv
        case "resp": return .respRate
        case "skin": return .skinTemp
        case "spo2": return .spo2
        default: return .recovery
        }
    }

    /// Last night pushes the night itself when one is stored; otherwise the sleep-hours history.
    @ViewBuilder
    private var sleepCard: some View {
        if let night = d.lastNight {
            NavigationLink { NightDetailView(night: night) } label: { sleepCardBody }
                .buttonStyle(.vPress)
                .accessibilityHint("Opens last night")
        } else {
            MetricLink(id: .sleepHours, dayKey: day?.day) { sleepCardBody }
        }
    }

    private var sleepCardBody: some View {
        VCard {
            VStack(alignment: .leading, spacing: VSpace.md) {
                VCardHeader(title: "Last night",
                            subtitle: d.lastNight.map { VFormat.clock($0.effectiveStartTs) + " – " + VFormat.clock($0.endTs) },
                            tint: VColor.sleep, systemImage: "moon.zzz.fill")
                if let day, day.totalSleepMin != nil {
                    HStack(alignment: .firstTextBaseline) {
                        Text(VFormat.hoursMinutes(day.totalSleepMin)).font(VFont.display).monospacedDigit()
                        Text("asleep").font(VFont.unit).foregroundStyle(VColor.textTertiary)
                        Spacer()
                        if let eff = day.efficiency {
                            VStack(alignment: .trailing, spacing: 0) {
                                Text("\(Int((eff * 100).rounded()))%").font(VFont.statSmall).monospacedDigit()
                                Text("efficiency").font(VFont.label).foregroundStyle(VColor.textTertiary)
                            }
                        }
                    }
                    VStageBar(awake: 0, light: day.lightMin ?? 0, rem: day.remMin ?? 0, deep: day.deepMin ?? 0)
                    HStack {
                        stageLegend("Deep", day.deepMin, VColor.stageDeep)
                        stageLegend("REM", day.remMin, VColor.stageRem)
                        stageLegend("Light", day.lightMin, VColor.stageLight)
                        Spacer()
                    }
                } else {
                    VEmpty(systemImage: "moon.zzz", title: "No sleep scored for this day",
                           message: "Sleep is staged from overnight HR and motion after the morning offload.")
                }
            }
        }
    }

    private func activityCard(_ day: DailyMetric) -> some View {
        HStack(spacing: VSpace.md) {
            MetricLink(id: .steps, dayKey: day.day) {
                VStatTile(title: "Steps", value: VFormat.int(day.steps), tint: VColor.strain, systemImage: "figure.walk")
            }
            MetricLink(id: .activeKcal, dayKey: day.day) {
                VStatTile(title: "Active energy", value: VFormat.int(day.activeKcalEst), unit: "kcal",
                          tint: VColor.rhr, systemImage: "flame")
            }
        }
    }

    private func stageLegend(_ name: String, _ minutes: Double?, _ color: Color) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(name).font(VFont.label).foregroundStyle(VColor.textSecondary)
            Text(VFormat.hoursMinutes(minutes)).font(.caption.weight(.semibold)).monospacedDigit()
        }
        .padding(.trailing, VSpace.sm)
    }

    /// The tab is already called Today, so the card says the date instead of repeating it.
    private func headerLabel(_ key: String) -> String {
        guard let d = VFormat.date(fromKey: key) else { return key }
        if Calendar.current.isDateInToday(d) { return d.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()) }
        return VFormat.dayLabel(key)
    }

    private func isRecent(_ key: String) -> Bool {
        guard let d = VFormat.date(fromKey: key) else { return false }
        return Calendar.current.isDateInToday(d) || Calendar.current.isDateInYesterday(d)
    }

    /// The headline describes the freshest scored day, which may be old (an import with no strap nights
    /// since). Say so rather than letting a two-month-old score pass as today's.
    private func staleNotice(_ key: String) -> some View {
        HStack(spacing: VSpace.sm) {
            Image(systemName: "info.circle.fill").foregroundStyle(VColor.textTertiary)
            Text("Latest scored day is \(VFormat.dayLabel(key)). Wear the strap overnight and today's score appears after the morning offload.")
                .font(.footnote).foregroundStyle(VColor.textSecondary)
        }
        .padding(VSpace.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(VColor.surface, in: RoundedRectangle(cornerRadius: VSpace.tileRadius, style: .continuous))
    }

    private func bandName(_ r: Double) -> String {
        switch VitalBand.recovery(r) {
        case .low: return "Low"
        case .mid: return "Moderate"
        case .high: return "Recovered"
        }
    }

    private func recoveryLine(_ r: Double) -> String {
        switch VitalBand.recovery(r) {
        case .low: return "Your body is signalling it needs rest. Keep today easy."
        case .mid: return "Ready for a moderate day. Listen to how you feel."
        case .high: return "Well recovered. A good day to push."
        }
    }
}

/// Gear button shared by every tab; opens Settings as a sheet.
struct SettingsToolbarButton: ToolbarContent {
    @State private var showing = false
    var body: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button { showing = true } label: { Image(systemName: "gearshape") }
                .sheet(isPresented: $showing) { SettingsScreen() }
        }
    }
}
