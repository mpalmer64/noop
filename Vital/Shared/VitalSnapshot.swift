import Foundation
#if canImport(WidgetKit)
import WidgetKit
#endif

/// The small glance the app publishes into the shared App Group for the widget extension. Compiled into
/// both the app and `VitalWidgets`. All fields optional so an older writer still decodes.
///
/// Cadence follows NOOP's precedent: the app republishes at most once a minute (from the derived-state
/// tick) and only reloads WidgetKit timelines when a rendered field actually changed.
struct VitalSnapshot: Codable, Equatable {
    var recovery: Double?
    /// Strain on NOOP's 0–100 Effort axis; the widget converts to WHOOP's 0–21 for display.
    var strain: Double?
    var rest: Double?
    var hrv: Double?
    var restingHr: Int?
    var bpm: Int?
    var batteryPct: Int?
    var connected: Bool = false
    /// The scored day the score fields describe (YYYY-MM-DD).
    var dayKey: String?
    var updated: Date = .distantPast

    static let storageKey = "vital.snapshot"

    /// App Group id from Info.plist (`AppGroupIdentifier`, wired to the entitlement in project.yml) so it
    /// is never hard-coded and tracks `BUNDLE_ID_PREFIX`.
    static let suiteName: String = {
        let configured = (Bundle.main.infoDictionary?["AppGroupIdentifier"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return configured.isEmpty ? "group.com.maxpalmer.vital" : configured
    }()

    static var placeholder: VitalSnapshot {
        VitalSnapshot(recovery: 72, strain: 38, rest: 81, hrv: 64, restingHr: 52, bpm: 58, batteryPct: 84,
                      connected: true, dayKey: nil, updated: Date())
    }

    static func load() -> VitalSnapshot? {
        guard let d = UserDefaults(suiteName: suiteName)?.data(forKey: storageKey) else { return nil }
        return try? JSONDecoder().decode(VitalSnapshot.self, from: d)
    }

    func save() {
        guard let d = try? JSONEncoder().encode(self) else { return }
        UserDefaults(suiteName: Self.suiteName)?.set(d, forKey: Self.storageKey)
    }

    /// Persist and ask WidgetKit to redraw only when something the widget renders changed; `updated` is
    /// metadata and never triggers a reload on its own.
    static func publish(_ snap: VitalSnapshot) {
        let previous = load()
        var stamped = snap
        stamped.updated = Date()
        stamped.save()
        #if canImport(WidgetKit)
        if previous.map({ $0.renderedFields != snap.renderedFields }) ?? true {
            WidgetCenter.shared.reloadAllTimelines()
        }
        #endif
    }

    private var renderedFields: [String] {
        [recovery, strain, rest, hrv].map { $0.map { String(format: "%.1f", $0) } ?? "" }
            + [restingHr, bpm, batteryPct].map { $0.map(String.init) ?? "" }
            + [connected ? "1" : "0", dayKey ?? ""]
    }
}
