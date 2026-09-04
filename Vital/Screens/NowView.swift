import SwiftUI

/// Phase 1 screen: one live number and enough controls to get a strap connected on a fresh install.
/// Deliberately undesigned; `Vital/Design/` tokens arrive with Phase 3.
struct NowView: View {
    @EnvironmentObject private var model: VitalModel
    @ObservedObject private var live: LiveState

    init(live: LiveState) { self.live = live }

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Text(live.heartRate.map(String.init) ?? "--")
                .font(.system(size: 96, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
                .animation(.default, value: live.heartRate)
            Text("BPM")
                .font(.headline)
                .foregroundStyle(.secondary)

            VStack(spacing: 6) {
                Text(status)
                if let pct = live.batteryPct {
                    Text("Battery \(Int(pct.rounded()))%")
                }
                if let err = live.lastSyncError {
                    Text(err).foregroundStyle(.red).multilineTextAlignment(.center)
                }
                if let hint = live.pairingHint ?? live.reconnectGuide {
                    Text(hint).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
            }
            .font(.subheadline)
            .padding(.horizontal)

            Spacer()

            HStack {
                Button("WHOOP 4.0") { model.connect(.whoop4) }
                Button("WHOOP 5.0 / MG") { model.connect(.whoop5mg) }
                Button("Disconnect", role: .destructive) { model.disconnect() }
            }
            .buttonStyle(.bordered)

            if let last = live.log.last {
                Text(last)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
                    .padding(.horizontal)
            }
        }
        .padding(.bottom)
    }

    private var status: String {
        if !live.connected { return "Not connected" }
        if !live.bonded { return "Connected, bonding…" }
        if live.backfilling { return "Connected · syncing" }
        return live.streamingLiveHR ? "Connected · live" : "Connected"
    }
}
