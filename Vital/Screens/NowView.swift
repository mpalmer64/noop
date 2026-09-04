import SwiftUI
import WhoopProtocol

/// Live screen: the only genuinely realtime data (heart rate, battery, link) plus the day's strain so far.
struct NowScreen: View {
    @EnvironmentObject private var model: VitalModel
    @ObservedObject private var live: LiveState
    @Environment(\.scenePhase) private var scenePhase

    init(live: LiveState) { self.live = live }

    var body: some View {
        VScreen(title: "Now") {
            heroCard
            HStack(spacing: VSpace.md) {
                VStatTile(title: "Day strain", value: VFormat.whoopStrain(model.derived.liveStrain),
                          tint: VColor.strain, systemImage: "flame.fill",
                          footnote: model.derived.liveStrain == nil ? "Accrues from today's banked HR" : "So far today")
                VStatTile(title: "Battery", value: live.batteryPct.map { "\(Int($0.rounded()))" } ?? "--",
                          unit: live.batteryPct == nil ? nil : "%",
                          tint: batteryTint, systemImage: live.charging == true ? "bolt.fill" : "battery.75percent",
                          footnote: live.charging == true ? "Charging" : nil)
            }
            todayHRCard
            syncCard
        }
        .toolbar { SettingsToolbarButton() }
        .onAppear { model.startRealtimeHR() }
        .onDisappear { model.stopRealtimeHR() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { model.appBecameActive() }
        }
    }

    // MARK: Pieces

    private var heroCard: some View {
        VCard(padding: VSpace.xl) {
            VStack(spacing: VSpace.md) {
                HStack {
                    connectionPill
                    Spacer()
                    if let fw = live.strapFirmware {
                        Text(live.whoop5Variant ?? (model.isWhoop5 ? "WHOOP 5.0" : "WHOOP 4.0"))
                            .font(VFont.caption).foregroundStyle(VColor.textTertiary)
                            .help(fw)
                    }
                }
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: "heart.fill")
                        .font(.title)
                        .foregroundStyle(VColor.heart)
                        .symbolEffect(.pulse, options: .repeating, isActive: model.bpm != nil)
                        .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 14 }
                    Text(model.bpm.map(String.init) ?? "--")
                        .font(VFont.hero)
                        .monospacedDigit()
                        .foregroundStyle(model.bpm == nil ? VColor.textTertiary : VColor.textPrimary)
                        .contentTransition(.numericText())
                        .animation(.snappy, value: model.bpm)
                    Text("bpm").font(.title3.weight(.medium)).foregroundStyle(VColor.textSecondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, VSpace.sm)
                if !live.connected {
                    connectButtons
                } else if let hint = live.pairingHint ?? live.reconnectGuide {
                    Text(hint).font(.footnote).foregroundStyle(VColor.textSecondary)
                        .multilineTextAlignment(.center)
                }
                if let err = live.lastSyncError {
                    Text(err).font(.footnote).foregroundStyle(VColor.recoveryLow).multilineTextAlignment(.center)
                }
            }
        }
    }

    private var connectionPill: some View {
        HStack(spacing: 6) {
            Circle().fill(connectionTint).frame(width: 8, height: 8)
                .shadow(color: connectionTint.opacity(0.7), radius: 4)
            Text(connectionText).font(.caption.weight(.semibold)).foregroundStyle(VColor.textSecondary)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(VColor.surfaceInset, in: Capsule())
    }

    private var connectionText: String {
        if !live.connected { return "Not connected" }
        if !live.bonded { return "Connected · bonding" }
        if live.backfilling { return "Connected · syncing" }
        return model.bpm != nil ? "Live" : "Connected"
    }

    private var connectionTint: Color {
        if !live.connected { return VColor.textTertiary }
        if !live.bonded { return VColor.recoveryMid }
        return VColor.recoveryHigh
    }

    private var batteryTint: Color {
        guard let p = live.batteryPct else { return VColor.textSecondary }
        return p < 20 ? VColor.recoveryLow : (p < 40 ? VColor.recoveryMid : VColor.recoveryHigh)
    }

    private var connectButtons: some View {
        HStack(spacing: VSpace.sm) {
            Button { model.connect(.whoop4) } label: { Text("Connect 4.0").frame(maxWidth: .infinity) }
            Button { model.connect(.whoop5mg) } label: { Text("Connect 5.0 / MG").frame(maxWidth: .infinity) }
        }
        .buttonStyle(.bordered)
        .tint(VColor.textPrimary)
    }

    private var todayHRCard: some View {
        let buckets = Self.bucket(model.derived.todayHR, seconds: 600)
        return VCard {
            VStack(alignment: .leading, spacing: VSpace.md) {
                VCardHeader(title: "Heart rate today",
                            subtitle: buckets.isEmpty ? nil : "\(model.derived.todayHR.count) samples",
                            tint: VColor.heart, systemImage: "waveform.path.ecg")
                if buckets.count >= 2 {
                    VSparkline(values: buckets, tint: VColor.heart, showsLast: true)
                        .frame(height: 120)
                    HStack {
                        stat("Low", model.derived.todayHR.map { Double($0.bpm) }.min())
                        Spacer()
                        stat("Avg", avg(model.derived.todayHR.map { Double($0.bpm) }))
                        Spacer()
                        stat("High", model.derived.todayHR.map { Double($0.bpm) }.max())
                    }
                } else {
                    VEmpty(systemImage: "waveform.path.ecg",
                           title: "No heart rate banked yet today",
                           message: "The strap buffers HR and offloads it in bursts every 15–20 minutes while connected.")
                }
            }
        }
    }

    private var syncCard: some View {
        VCard {
            VStack(alignment: .leading, spacing: VSpace.sm) {
                VCardHeader(title: "Strap sync", tint: VColor.textSecondary, systemImage: "arrow.triangle.2.circlepath")
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.sync.backfilling ? "Offloading history…" : "Last offload")
                            .font(.footnote).foregroundStyle(VColor.textSecondary)
                        Text(model.sync.backfilling ? "\(model.sync.chunksThisSession) chunks this session"
                                                    : VFormat.relative(model.sync.lastSyncedAt))
                            .font(VFont.statSmall).monospacedDigit()
                    }
                    Spacer()
                    Button("Sync now") { model.syncNow() }
                        .buttonStyle(.bordered)
                        .disabled(!live.bonded || model.sync.backfilling)
                }
                Text("HRV, sleep, strain and respiration come from history the strap offloads on connection, then get scored on this phone. Only heart rate and battery are live.")
                    .font(.caption2).foregroundStyle(VColor.textTertiary)
            }
        }
    }

    private func stat(_ label: String, _ v: Double?) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(VFont.label).foregroundStyle(VColor.textTertiary)
            Text(VFormat.int(v)).font(VFont.statSmall).monospacedDigit()
        }
    }

    private func avg(_ xs: [Double]) -> Double? {
        xs.isEmpty ? nil : xs.reduce(0, +) / Double(xs.count)
    }

    /// Mean bpm per fixed window, dropping empty windows so the sparkline stays continuous.
    static func bucket(_ samples: [HRSample], seconds: Int) -> [Double] {
        guard let first = samples.first?.ts else { return [] }
        var sums: [Int: (Double, Int)] = [:]
        for s in samples {
            let k = (s.ts - first) / seconds
            let cur = sums[k] ?? (0, 0)
            sums[k] = (cur.0 + Double(s.bpm), cur.1 + 1)
        }
        return sums.keys.sorted().map { sums[$0]!.0 / Double(sums[$0]!.1) }
    }
}
