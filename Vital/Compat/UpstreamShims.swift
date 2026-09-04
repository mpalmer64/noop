// UpstreamShims.swift — Vital-local stand-ins for NOOP app-layer symbols that the shared
// WHOOP collection layer (Strand/BLE, Strand/Collect) references but Vital does not compile.
//
// Vital compiles the collection layer straight from the shared tree (see the `Vital` target in
// project.yml) and never compiles NOOP's AppModel, AppChangelog, or IntelligenceEngine. Each type
// below carries ONLY the members the collection layer calls, with behaviour matching upstream where
// it matters at runtime and a documented no-op where it does not.
//
// When a rebase onto upstream breaks the Vital build with "cannot find X in scope", the missing
// symbol almost certainly belongs here. Keep this the single place such shims live.
//
// Shim                                    Stands in for                      Referenced from
// ----------------------------------------------------------------------------------------------
// AppChangelog.currentVersion             Strand/System/AppChangelog.swift   BLEManager (one-shot
//                                                                            per-version replay key)
// IntelligenceEngine.requestTimestampReheal  Strand/Data/IntelligenceEngine.swift  BLEManager (bad-clock
//                                                                            strap detected → flag a heal)
// AppModel.postInactivity(minutes:)       Strand/App/AppModel.swift          BLEManager (sedentary
//                                                                            detector → local notification)
//
// Phase 2 note: when Vital compiles the real IntelligenceEngine (option (a) in the build spec), delete
// the IntelligenceEngine shim below; the other two stay.

import Foundation
import UserNotifications

/// Stand-in for NOOP's `AppChangelog`. BLEManager compares this against a persisted key so a
/// per-version one-shot (a firmware-flag replay) runs once per app version. Vital's own marketing
/// version is the right key for that, so the one-shot fires once per Vital release.
enum AppChangelog {
    static let currentVersion: String =
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0"
}

/// Stand-in for NOOP's `IntelligenceEngine`. Upstream sets a UserDefaults flag that its next scoring
/// pass reads to purge implausibly-timestamped rows (#547). Vital writes the SAME key so that when the
/// real engine is compiled in (Phase 2) a heal requested under Phase 1 is still honoured.
enum IntelligenceEngine {
    /// Mirrors `IntelligenceEngine.timestampHealPendingKey` upstream.
    static let timestampHealPendingKey = "intelligence.timestampHeal.v547.pending"

    static func requestTimestampReheal() {
        UserDefaults.standard.set(true, forKey: timestampHealPendingKey)
    }
}

/// Stand-in for NOOP's `AppModel`. Only the static entry the sedentary detector in BLEManager calls.
/// Posts a local notification if the user has granted notification permission; silent otherwise.
/// Vital does not request that permission in Phase 1, so this is effectively a no-op until it does.
enum AppModel {
    static func postInactivity(minutes: Int) {
        let content = UNMutableNotificationContent()
        content.title = "Move reminder"
        content.body = minutes > 0
            ? "You've been seated for about \(minutes) min. Time to move."
            : "Time to move. You've been seated a while."
        let request = UNNotificationRequest(identifier: "inactivity-nudge", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
