import Combine
import Foundation

/// The one object Vital's views talk to. Phase 1: owns the shared WHOOP collection layer and exposes
/// its live channel. Phase 2 adds sync state, derived (scored) state, and the smoothed BPM.
///
/// `LiveState` and `BLEManager` are NOOP's own types, compiled into this target from `Strand/BLE`.
/// `BLEManager` opens the SQLite store, registry, collector and backfiller itself once the central
/// reaches `poweredOn`, then auto-connects to the persisted strap model (see
/// `BLEManager.centralManagerDidUpdateState`). Nothing here needs to kick that off.
@MainActor
final class VitalModel: ObservableObject {
    /// Raw live channel: `heartRate` (per-frame, unsmoothed), `connected`, `bonded`, `batteryPct`,
    /// `lastSyncedAt`, `backfilling`, and the strap log. Observe it directly from views.
    let live: LiveState
    let ble: BLEManager

    init() {
        let live = LiveState()
        self.live = live
        self.ble = BLEManager(state: live)
    }

    /// Pick a strap family and (re)connect. Persists the choice the same way NOOP does so the next
    /// launch auto-connects to the right family without asking.
    func connect(_ model: WhoopModel) {
        UserDefaults.standard.set(model.rawValue, forKey: "selectedWhoopModel")
        ble.connect(model: model)
    }

    func disconnect() { ble.disconnect() }
}
