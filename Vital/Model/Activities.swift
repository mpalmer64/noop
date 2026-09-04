import Foundation
import StrandAnalytics
import WhoopProtocol
import WhoopStore

/// A workout in progress. Samples are the smoothed live BPM, one per change, exactly what NOOP's
/// `ActiveWorkout` records; strain/kcal/zones are computed from them at the end (and live, for display).
struct ActiveActivity: Codable, Equatable {
    let start: Date
    var sport: String
    var samples: [HRSample] = []
    var pausedAt: Date?
    var pausedDuration: TimeInterval = 0

    var isPaused: Bool { pausedAt != nil }

    func elapsed(at now: Date = Date()) -> TimeInterval {
        let pausedNow = pausedAt.map { now.timeIntervalSince($0) } ?? 0
        return max(0, now.timeIntervalSince(start) - pausedDuration - pausedNow)
    }

    var avgHr: Int? {
        guard !samples.isEmpty else { return nil }
        return Int((Double(samples.map(\.bpm).reduce(0, +)) / Double(samples.count)).rounded())
    }
    var peakHr: Int? { samples.map(\.bpm).max() }

    static let storageKey = "vital.activity.active"
    static func load() -> ActiveActivity? {
        guard let d = UserDefaults.standard.data(forKey: storageKey) else { return nil }
        return try? JSONDecoder().decode(ActiveActivity.self, from: d)
    }
    func save() {
        if let d = try? JSONEncoder().encode(self) { UserDefaults.standard.set(d, forKey: Self.storageKey) }
    }
    static func clear() { UserDefaults.standard.removeObject(forKey: storageKey) }
}

/// Zone time as percentages in the same `{"z1":…,"z5":…}` shape the WHOOP importer stores, so detail views
/// read every source identically.
enum ActivityZones {
    static func json(_ tiz: TimeInZone) -> String? {
        let total = tiz.total
        guard total > 0 else { return nil }
        var d: [String: Double] = [:]
        for z in 1...5 { d["z\(z)"] = tiz.seconds(inZone: z) / total * 100 }
        return (try? JSONSerialization.data(withJSONObject: d)).flatMap { String(data: $0, encoding: .utf8) }
    }

    /// Percentages z1…z5 from stored JSON (either source).
    static func percentages(_ json: String?) -> [Double]? {
        guard let json, let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let vals = (1...5).map { (obj["z\($0)"] as? NSNumber)?.doubleValue ?? 0 }
        return vals.reduce(0, +) > 0 ? vals : nil
    }
}

@MainActor
extension VitalModel {

    // MARK: Start / pause / end

    func startActivity(sport: String) {
        guard activity == nil else { return }
        let name = sport.trimmingCharacters(in: .whitespaces)
        var a = ActiveActivity(start: Date(), sport: name.isEmpty ? WorkoutCatalog.defaultSportName : name)
        if let hr = bpm { a.samples.append(HRSample(ts: Int(Date().timeIntervalSince1970), bpm: hr)) }
        activity = a
        a.save()
        lastCoachZone = -1
        startRealtimeHR()   // keep the feed up for the whole session, not only while Now is showing
        buzz(loops: 1, gate: HapticPrefs.workout)
        refreshActivityLive()
    }

    func pauseActivity() {
        guard var a = activity, !a.isPaused else { return }
        a.pausedAt = Date()
        activity = a; a.save()
        buzz(loops: 1, gate: HapticPrefs.workout)
    }

    func resumeActivity() {
        guard var a = activity, let p = a.pausedAt else { return }
        a.pausedDuration += Date().timeIntervalSince(p)
        a.pausedAt = nil
        activity = a; a.save()
        buzz(loops: 1, gate: HapticPrefs.workout)
    }

    func discardActivity() {
        guard activity != nil else { return }
        activity = nil
        activityLive = nil
        ActiveActivity.clear()
        stopRealtimeHR()
    }

    /// Finish: same row NOOP's `endWorkout` writes (source "manual", strain via StrainScorer, kcal via
    /// Calories) plus zone percentages so the detail view can draw them without re-reading HR.
    func endActivity() async {
        guard let a = activity else { return }
        activity = nil
        activityLive = nil
        ActiveActivity.clear()
        stopRealtimeHR()
        let end = Date()
        let row = buildWorkoutRow(sport: a.sport, start: a.start, end: end,
                                  activeSeconds: a.elapsed(at: end), samples: a.samples, source: "manual")
        buzz(loops: 2, gate: HapticPrefs.workout)
        await persist(row)
    }

    /// Log a past activity. HR the strap already banked for that window gives it avg/peak/strain/kcal,
    /// like WHOOP's retroactive "add activity".
    func logActivity(sport: String, start: Date, end: Date) async {
        guard end > start else { return }
        let samples = await repo.hrSamples(from: Int(start.timeIntervalSince1970),
                                           to: Int(end.timeIntervalSince1970), limit: 20_000)
        let row = buildWorkoutRow(sport: sport, start: start, end: end,
                                  activeSeconds: end.timeIntervalSince(start), samples: samples, source: "manual")
        await persist(row)
    }

    func deleteActivity(_ row: WorkoutRow) async {
        await repo.deleteWorkout(row)
        await reloadWorkouts()
    }

    private func persist(_ row: WorkoutRow) async {
        if let store = await repo.storeHandle() {
            _ = try? await store.upsertWorkouts([row], deviceId: Self.deviceId)
            await repo.refresh()
        }
        await reloadWorkouts()
        await recomputeDerived()
    }

    private func buildWorkoutRow(sport: String, start: Date, end: Date, activeSeconds: TimeInterval,
                                 samples: [HRSample], source: String) -> WorkoutRow {
        let restingHR = derived.anchor?.restingHr.map(Double.init) ?? StrainScorer.defaultRestingHR
        let enough = samples.count >= 2
        let strain = enough ? StrainScorer.strain(samples, maxHR: Double(profile.hrMax), restingHR: restingHR,
                                                  method: PuffinExperiment.effortMethod, sex: profile.sex) : nil
        let up = UserProfile(weightKg: profile.weightKg, heightCm: profile.heightCm,
                             age: Double(profile.age), sex: profile.sex)
        let kcal = enough ? Calories.estimateBoutCalories(samples, profile: up, hrmax: Double(profile.hrMax),
                                                          restingHR: restingHR).0 : 0
        let zones = enough ? ActivityZones.json(HRZones.timeInZone(samples, zoneSet: profile.hrZoneSet)) : nil
        let avg = samples.isEmpty ? nil : Int((Double(samples.map(\.bpm).reduce(0, +)) / Double(samples.count)).rounded())
        return WorkoutRow(startTs: Int(start.timeIntervalSince1970), endTs: Int(end.timeIntervalSince1970),
                          sport: sport, source: source, durationS: activeSeconds,
                          energyKcal: kcal > 0 ? kcal : nil, avgHr: avg, maxHr: samples.map(\.bpm).max(),
                          strain: strain, distanceM: nil, zonesJSON: zones, notes: nil, steps: nil)
    }

    // MARK: Live updates

    /// Called from `ingestHR` on every smoothed-BPM change while a session is running.
    func captureActivitySample() {
        guard var a = activity, !a.isPaused, let hr = bpm else { return }
        a.samples.append(HRSample(ts: Int(Date().timeIntervalSince1970), bpm: hr))
        activity = a
        if a.samples.count % 15 == 0 { a.save() }   // crash-safe without hammering defaults
        refreshActivityLive()
    }

    /// Strain so far and time in zones, recomputed on each sample (StrainScorer memoises).
    func refreshActivityLive() {
        guard let a = activity else { activityLive = nil; return }
        let restingHR = derived.anchor?.restingHr.map(Double.init) ?? StrainScorer.defaultRestingHR
        let strain = a.samples.count >= 2
            ? StrainScorer.strain(a.samples, maxHR: Double(profile.hrMax), restingHR: restingHR,
                                  method: PuffinExperiment.effortMethod, sex: profile.sex) : nil
        let tiz = HRZones.timeInZone(a.samples, zoneSet: profile.hrZoneSet)
        let up = UserProfile(weightKg: profile.weightKg, heightCm: profile.heightCm,
                             age: Double(profile.age), sex: profile.sex)
        let kcal = a.samples.count >= 2
            ? Calories.estimateBoutCalories(a.samples, profile: up, hrmax: Double(profile.hrMax), restingHR: restingHR).0
            : 0
        activityLive = ActivityLive(strain: strain, zoneSeconds: (1...5).map { tiz.seconds(inZone: $0) },
                                    kcal: kcal, currentZone: bpm.map { profile.hrZoneSet.zoneNumber(forBPM: Double($0)) } ?? 0)
    }

    func restoreActivityIfNeeded() {
        guard activity == nil, let saved = ActiveActivity.load() else { return }
        activity = saved
        startRealtimeHR()
        refreshActivityLive()
    }

    func reloadWorkouts() async {
        workouts = await repo.workoutRows(days: 180).sorted { $0.startTs > $1.startTs }
    }
}

struct ActivityLive: Equatable {
    var strain: Double?
    var zoneSeconds: [Double]
    var kcal: Double
    var currentZone: Int
}
