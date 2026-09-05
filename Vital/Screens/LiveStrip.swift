import SwiftUI
import WhoopProtocol

/// Everything the live strip shows, as plain values. `TodayScreen` builds one from `VitalModel` + `LiveState`;
/// previews and the prototype gallery build them by hand, so the strip renders without a `BLEManager`.
struct LiveStripState: Equatable {
    var bpm: Int?
    var connected = false
    var bonded = false
    var backfilling = false
    var batteryPct: Double?
    var charging = false
    var modelLabel: String?
    var lastSynced: Date?
    var hint: String?
    var error: String?

    var statusText: String {
        if !connected { return "Not connected" }
        if !bonded { return "Bonding" }
        if backfilling { return "Syncing" }
        return bpm != nil ? "Live" : "Connected"
    }

    var statusTint: Color {
        if !connected { return VColor.textTertiary }
        if !bonded { return VColor.recoveryMid }
        return VColor.recoveryHigh
    }

    var batteryTint: Color {
        guard let p = batteryPct else { return VColor.textSecondary }
        return p < 20 ? VColor.recoveryLow : (p < 40 ? VColor.recoveryMid : VColor.recoveryHigh)
    }

    var batteryText: String { batteryPct.map { "\(Int($0.rounded()))%" } ?? "--" }
    var batterySymbol: String {
        if charging { return "bolt.fill" }
        guard let p = batteryPct else { return "battery.0percent" }
        return p < 20 ? "battery.25percent" : (p < 60 ? "battery.50percent" : "battery.100percent")
    }

    var syncText: String {
        backfilling ? "Offloading history…" : "Synced \(VFormat.relative(lastSynced))"
    }

    // Sample states for previews and the gallery.
    static let live = LiveStripState(bpm: 68, connected: true, bonded: true, batteryPct: 51, modelLabel: "WHOOP 5.0",
                                     lastSynced: Date().addingTimeInterval(-12 * 60))
    static let syncing = LiveStripState(bpm: 74, connected: true, bonded: true, backfilling: true, batteryPct: 51,
                                        modelLabel: "WHOOP 5.0", lastSynced: Date().addingTimeInterval(-3 * 3600))
    static let bonding = LiveStripState(connected: true, bonded: false, batteryPct: nil, modelLabel: "WHOOP 5.0",
                                        hint: "Accept the pairing request on your phone.")
    static let disconnected = LiveStripState(lastSynced: Date().addingTimeInterval(-26 * 3600))
}

/// What the strip can do. Kept separate so previews pass no-ops.
struct LiveStripActions {
    var connect: (WhoopModel) -> Void = { _ in }
    var sync: () -> Void = {}
    static let none = LiveStripActions()
}

// MARK: - Shared pieces (every variant composes these)

/// Heart symbol that bounces on each new reading, plus the numeral. Sized by the caller.
struct LiveBPM: View {
    let bpm: Int?
    var numeralFont: Font = VFont.stat
    var heartFont: Font = .body
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: VSpace.xs) {
            Image(systemName: "heart.fill")
                .font(heartFont)
                .foregroundStyle(VColor.heart)
                .symbolEffect(.bounce, options: .nonRepeating, value: reduceMotion ? 0 : (bpm ?? 0))
            Text(bpm.map(String.init) ?? "--")
                .font(numeralFont).monospacedDigit()
                .foregroundStyle(bpm == nil ? VColor.textTertiary : VColor.textPrimary)
                .contentTransition(.numericText())
                .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: bpm)
            Text("bpm").font(VFont.unit).foregroundStyle(VColor.textTertiary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(bpm.map { "Heart rate \($0) beats per minute" } ?? "Heart rate unavailable")
    }
}

struct LiveStatusDot: View {
    let state: LiveStripState
    var body: some View {
        Circle().fill(state.statusTint).frame(width: VSpace.sm, height: VSpace.sm)
            .shadow(color: state.statusTint.opacity(0.7), radius: VSpace.xs)
            .accessibilityHidden(true)
    }
}

struct LiveBattery: View {
    let state: LiveStripState
    var body: some View {
        HStack(spacing: VSpace.xs) {
            Image(systemName: state.batterySymbol).font(.caption.weight(.semibold)).foregroundStyle(state.batteryTint)
            Text(state.batteryText).font(VFont.label).monospacedDigit().foregroundStyle(VColor.textSecondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Strap battery \(state.batteryText)\(state.charging ? ", charging" : "")")
    }
}

/// "Synced 12 min ago · Sync now" as one line. The action is inline text, not a bordered button.
struct LiveSyncLine: View {
    let state: LiveStripState
    let actions: LiveStripActions
    var body: some View {
        HStack(spacing: VSpace.sm) {
            Image(systemName: "arrow.triangle.2.circlepath").font(.caption2)
            Text(state.syncText)
            if state.connected {
                Text("·")
                Button("Sync now") { actions.sync() }
                    .disabled(!state.bonded || state.backfilling)
                    .foregroundStyle(state.bonded && !state.backfilling ? VColor.hrv : VColor.textTertiary)
                    .accessibilityHint("Asks the strap to offload now")
            }
            Spacer(minLength: 0)
        }
        .font(VFont.caption).foregroundStyle(VColor.textTertiary)
        .buttonStyle(.plain)
    }
}

struct LiveConnectButtons: View {
    let actions: LiveStripActions
    var body: some View {
        HStack(spacing: VSpace.sm) {
            Button { actions.connect(.whoop4) } label: { Text("Connect 4.0").frame(maxWidth: .infinity) }
            Button { actions.connect(.whoop5mg) } label: { Text("Connect 5.0 / MG").frame(maxWidth: .infinity) }
        }
        .buttonStyle(.bordered)
        .tint(VColor.textPrimary)
    }
}

// MARK: - The strip (variant A "Ticker", picked from three prototypes)

/// Compact live row above the Today rings: heart + BPM (tap → heart-rate Day detail), status pill, battery,
/// strap model; "Synced … · Sync now" beneath. Disconnected shows the two Connect buttons inline.
struct LiveStrip: View {
    let state: LiveStripState
    var actions: LiveStripActions = .none

    var body: some View {
        VStack(alignment: .leading, spacing: VSpace.sm) {
            HStack(spacing: VSpace.md) {
                MetricLink(id: .hr, dayKey: VitalDay.todayKey()) {
                    LiveBPM(bpm: state.bpm, numeralFont: VFont.stat, heartFont: .subheadline)
                        .contentShape(Rectangle())
                }
                Spacer(minLength: 0)
                HStack(spacing: VSpace.xs) {
                    LiveStatusDot(state: state)
                    Text(state.statusText).font(.caption.weight(.semibold)).foregroundStyle(VColor.textSecondary)
                }
                .padding(.horizontal, VSpace.sm).padding(.vertical, VSpace.xs)
                .background(VColor.surfaceInset, in: Capsule())
                .accessibilityLabel("Strap \(state.statusText)")
                if state.connected { LiveBattery(state: state) }
                if let m = state.modelLabel, state.connected {
                    Text(m).font(VFont.caption).foregroundStyle(VColor.textTertiary)
                }
            }
            if !state.connected { LiveConnectButtons(actions: actions) }
            else if let hint = state.hint { Text(hint).font(.footnote).foregroundStyle(VColor.textSecondary) }
            if let err = state.error { Text(err).font(.footnote).foregroundStyle(VColor.recoveryLow) }
            LiveSyncLine(state: state, actions: actions)
        }
        .padding(VSpace.md)
        .background(VColor.surface, in: RoundedRectangle(cornerRadius: VSpace.tileRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: VSpace.tileRadius, style: .continuous).strokeBorder(VColor.hairline, lineWidth: 1))
    }
}

#Preview("Live") { LiveStrip(state: .live).padding().background(VColor.canvas) }
#Preview("Syncing") { LiveStrip(state: .syncing).padding().background(VColor.canvas) }
#Preview("Bonding") { LiveStrip(state: .bonding).padding().background(VColor.canvas) }
#Preview("Disconnected") { LiveStrip(state: .disconnected).padding().background(VColor.canvas) }
