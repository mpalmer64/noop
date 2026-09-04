import Combine
import Foundation

/// The one object Vital's views talk to. Phase 1: owns the shared WHOOP collection layer and exposes
/// its live channel. Phase 2 adds sync state, derived (scored) state, and the smoothed BPM.
///
/// `LiveState` and `BLEManager` are NOOP's own types, compiled into this target from `Strand/BLE`.
/// `BLEManager` opens the SQLite store, registry, collector and backfiller itself once the central
/// reaches `poweredOn`, then auto-connects to the persisted strap model (see
/// `BLEManager.centralManagerDidUpdateState`). Nothing here needs to kick that off.
///
/// Live heart rate is NOT on by default: a bonded strap only offloads history until something asks
/// for the realtime feed (`BLEManager.startRealtime()` sends the toggle command and enables the HR
/// notifications). NOOP's Live screen requests it on appear and re-arms it after every (re)bond; the
/// wanter-count + re-arm below mirrors `AppModel.startRealtimeHR` / `rearmRealtimeIfWanted`.
@MainActor
final class VitalModel: ObservableObject {
    /// Raw live channel: `heartRate` (per-frame, unsmoothed), `connected`, `bonded`, `batteryPct`,
    /// `lastSyncedAt`, `backfilling`, and the strap log. Observe it directly from views.
    let live: LiveState
    let ble: BLEManager

    private var realtimeWanters = 0
    private var cancellables = Set<AnyCancellable>()

    init() {
        let live = LiveState()
        self.live = live
        self.ble = BLEManager(state: live)
        // A bond that lands while a screen already wants live HR must re-arm the feed: the toggle sent
        // before the bond is lost with the old link. Same edge NOOP's Live screen reacts to.
        live.$bonded
            .removeDuplicates()
            .filter { $0 }
            .sink { [weak self] _ in self?.rearmRealtimeIfWanted() }
            .store(in: &cancellables)
    }

    /// Pick a strap family and (re)connect. Persists the choice the same way NOOP does so the next
    /// launch auto-connects to the right family without asking.
    func connect(_ model: WhoopModel) {
        UserDefaults.standard.set(model.rawValue, forKey: "selectedWhoopModel")
        ble.connect(model: model)
    }

    func disconnect() { ble.disconnect() }

    // MARK: Live HR feed (wanter-counted, one BLE toggle regardless of how many screens ask)

    func startRealtimeHR() {
        if realtimeWanters == 0 { ble.startRealtime() }
        realtimeWanters += 1
    }

    func stopRealtimeHR() {
        realtimeWanters = max(0, realtimeWanters - 1)
        if realtimeWanters == 0 { ble.stopRealtime() }
    }

    func rearmRealtimeIfWanted() {
        guard realtimeWanters > 0 else { return }
        ble.startRealtime()
    }
}
