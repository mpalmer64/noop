import Combine
import Foundation
import StrandAnalytics
import UserNotifications
import StrandImport
import WhoopProtocol
import WhoopStore

/// The one object Vital's views talk to. Owns NOOP's collection layer (`LiveState` + `BLEManager`),
/// its read model (`Repository`), its profile (`ProfileStore`) and its scoring orchestrator
/// (`IntelligenceEngine`), all compiled from the shared tree so every number matches NOOP.
///
/// Three channels, per the build spec:
///  - **Live** (`bpm`, `live.connected`, `live.batteryPct`): the only genuinely realtime data.
///  - **Sync** (`sync`): when the strap last offloaded, whether a backfill is running.
///  - **Derived** (`derived`): recovery / strain / HRV / sleep, recomputed after each offload or import,
///    never per render. Every derived value carries the day it describes and when it was computed.
@MainActor
final class VitalModel: ObservableObject {
    /// NOOP's registry seeds a single active strap under this id (migration v15); imports land under the
    /// same id so the dashboard merge treats them as one device's history.
    static let deviceId = "my-whoop"

    let live: LiveState
    let ble: BLEManager
    let repo: Repository
    let profile: ProfileStore
    let intelligence: IntelligenceEngine

    /// Smoothed display heart rate: median over a ~10 s window, spike-filtered. Port of
    /// `AppModel.ingestHR`; a raw per-beat value swings with HRV and a single bad frame reads 170+.
    @Published private(set) var bpm: Int?
    @Published private(set) var sync = VitalSync()
    @Published private(set) var derived = VitalDerived()
    @Published private(set) var importStatus: VitalImportStatus = .idle
    @Published private(set) var isScoring = false
    /// Workout in progress (see Activities.swift) and its live-computed numbers.
    @Published var activity: ActiveActivity?
    @Published var activityLive: ActivityLive?
    @Published var workouts: [WorkoutRow] = []
    /// Strain coach target for the anchor day (see Coach.swift); nil until a recovery exists.
    var strainCoach: StrainCoach? { StrainCoach(recovery: derived.anchor?.recovery) }
    var lastCoachZone = -1
    /// Drill-down series cache (Vital/Data/MetricLoader.swift). Cleared wherever stored data changes.
    let metricCache = MetricCache()

    var isWhoop5: Bool { ble.isWhoop5 }

    private var realtimeWanters = 0
    private var hrWindow: [(t: Date, v: Double)] = []
    private var cancellables = Set<AnyCancellable>()
    private var started = false
    private var derivedTimer: Timer?

    init() {
        let live = LiveState()
        self.live = live
        self.ble = BLEManager(state: live, deviceId: Self.deviceId)
        self.repo = Repository(deviceId: Self.deviceId)
        self.profile = ProfileStore()
        self.intelligence = IntelligenceEngine(repo: repo, profile: profile, deviceId: Self.deviceId)

        intelligence.diagnosticSink = { [live] line, domain in live.append(log: line, domain: domain) }
        repo.strainProfile = Repository.StrainProfile(hrMax: Double(profile.hrMax), sex: profile.sex)
        profile.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.repo.strainProfile = Repository.StrainProfile(hrMax: Double(self.profile.hrMax),
                                                                   sex: self.profile.sex)
            }
            .store(in: &cancellables)

        live.$heartRate.sink { [weak self] _ in self?.ingestHR() }.store(in: &cancellables)
        live.$rr.sink { [weak self] _ in self?.ingestHR() }.store(in: &cancellables)

        // Strap-side hooks: double-tap → haptic clock; BLE sedentary detector → buzz (via the AppModel shim).
        live.onDoubleTap = { [weak self] in self?.handleDoubleTap() }
        AppModel.onInactivity = { [weak self] _ in
            guard VitalHaptics.enabled(VitalHaptics.moveReminderKey) else { return }
            self?.buzz(loops: 1)
        }

        // A bond that lands while a screen already wants live HR must re-arm the feed.
        live.$bonded
            .removeDuplicates()
            .filter { $0 }
            .sink { [weak self] _ in
                self?.rearmRealtimeIfWanted()
                self?.applyAlarm()
            }
            .store(in: &cancellables)

        // Sync channel mirrors LiveState fields the UI cares about.
        Publishers.CombineLatest3(live.$lastSyncedAt, live.$backfilling, live.$syncChunksThisSession)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] last, backfilling, chunks in
                self?.sync = VitalSync(lastSyncedAt: last.map { Date(timeIntervalSince1970: $0) },
                                       backfilling: backfilling,
                                       chunksThisSession: chunks)
            }
            .store(in: &cancellables)

        // Same trigger NOOP uses: a completed offload stamps `lastSyncedAt`; debounce the per-slice stamps
        // and re-score once. (AppModel.refreshAfterCompletedBackfill.)
        live.$lastSyncedAt
            .dropFirst()
            .compactMap { $0 }
            .removeDuplicates()
            .debounce(for: .seconds(2), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { [weak self] in await self?.refreshAfterSync() }
            }
            .store(in: &cancellables)
    }

    // MARK: Lifecycle

    /// Called once from the app's root `.task`. Surfaces whatever is already stored, seeds from the bundled
    /// export on first run, then runs the same scoring pass NOOP runs at launch.
    func start() async {
        guard !started else { return }
        started = true
        await repo.refresh()
        await recomputeDerived()
        restoreActivityIfNeeded()
        await reloadWorkouts()
        await seedFromBundleIfNeeded()
        await runScoring(force: false, skipIfUnchanged: false)
        applyWindDown()
        derivedTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.recomputeDerived()
                self?.hapticTick()
            }
        }
    }

    func appBecameActive() {
        rearmRealtimeIfWanted()
        Task { await recomputeDerived() }
    }

    private func refreshAfterSync() async {
        await repo.refresh(days: 120)
        metricCache.invalidate()
        await runScoring(force: false, skipIfUnchanged: true)
    }

    /// The scoring pass: timestamp heal (if flagged), then `analyzeRecent`, then a refresh so `repo.days`
    /// carries the new rows. Inline (foreground) — Vital registers no background task yet.
    func runScoring(force: Bool, skipIfUnchanged: Bool) async {
        guard !isScoring else { return }
        isScoring = true
        defer { isScoring = false }
        await intelligence.runTimestampHealIfNeeded()
        await RescoreBackgroundScheduler.run(isBackground: false, owesOnDefer: false,
                                             log: { [live] line in live.append(log: line) }) {
            await self.intelligence.analyzeRecent(force: force, skipIfUnchanged: skipIfUnchanged)
        }
        await repo.refresh()
        metricCache.invalidate()
        await recomputeDerived()
    }

    // MARK: Strap

    func connect(_ model: WhoopModel) {
        UserDefaults.standard.set(model.rawValue, forKey: "selectedWhoopModel")
        ble.connect(model: model)
    }

    func disconnect() { ble.disconnect() }
    func syncNow() { ble.syncNow() }

    // MARK: Live HR feed (wanter-counted; one BLE toggle however many screens ask)

    func startRealtimeHR() {
        if realtimeWanters == 0 {
            resetSmoothing()
            ble.startRealtime()
        }
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

    private func ingestHR() {
        var inst: Double?
        if let hr = live.heartRate, hr >= 30, hr <= 220 {
            inst = Double(hr)
        } else if let rr = live.rr.last, rr > 0 {
            let v = 60_000.0 / Double(rr)
            if v >= 30, v <= 220 { inst = v }
        }
        guard let inst else {
            if live.heartRate == nil && live.rr.isEmpty { resetSmoothing() }
            return
        }
        let now = Date()
        hrWindow.append((now, inst))
        hrWindow.removeAll { now.timeIntervalSince($0.t) > 10 }
        if hrWindow.count > 40 { hrWindow.removeFirst(hrWindow.count - 40) }
        let vals = hrWindow.map(\.v).sorted()
        let smoothed = vals.isEmpty ? nil : Int(vals[vals.count / 2].rounded())
        if bpm != smoothed {
            bpm = smoothed
            captureActivitySample()
            coachZone(smoothed)
        }
    }

    private func resetSmoothing() {
        hrWindow.removeAll()
        bpm = nil
    }

    // MARK: Derived state

    /// Recompute everything the Today / Sleep / Trends screens show. Cheap enough to run on a 60 s timer
    /// and after every refresh; heavy work (scoring) never happens here.
    func recomputeDerived() async {
        let now = Date()
        let days = repo.days
        let anchor = Repository.widgetAnchor(days: days, now: now)
        let todayKey = Repository.localDayKey(now)

        // Rest (sleep performance) lives in the metric series, not on DailyMetric. Same resolution the
        // widget uses: anchor day's row, or the tail only when the anchor IS today (a fresh day may not
        // have its row yet). Borrowing the tail for an older anchor would surface a different day's Rest.
        var restScore: Double?
        if let anchor {
            let rest = await repo.exploreSeries(key: "sleep_performance", source: Self.deviceId)
            let byDay = Dictionary(rest.map { ($0.day, $0.value) }, uniquingKeysWith: { _, last in last })
            restScore = byDay[anchor.day] ?? (anchor.day == todayKey ? rest.last?.value : nil)
        }

        let nowSec = Int(now.timeIntervalSince1970)
        let recent = await repo.sleepSessions(from: nowSec - 40 * 3600, to: nowSec, limit: 20)
        // "Last night": the longest session that ended in the last 24 h; naps are short.
        let lastNight = recent
            .filter { $0.endTs >= nowSec - 24 * 3600 && $0.endTs > $0.effectiveStartTs }
            .max { ($0.endTs - $0.effectiveStartTs) < ($1.endTs - $1.effectiveStartTs) }

        let dayStart = Int(Calendar.current.startOfDay(for: now).timeIntervalSince1970)
        // Full day at 1 Hz is ~86k rows; the store returns ASC with LIMIT, so a small cap silently reads
        // only the small hours (asleep → strain 0.0). Same window NOOP's TodayView scores live.
        let todayHR = await repo.hrSamples(from: dayStart, to: nowSec, limit: 100_000)
        // Live day strain: NOOP's TodayView recipe, verbatim (Tanaka HRmax from age, the anchor day's
        // resting HR, the configured effort method).
        let maxHR = profile.age > 0 ? StrainScorer.tanakaHRmax(age: Double(profile.age)) : nil
        let restHR = anchor?.restingHr.map(Double.init) ?? StrainScorer.defaultRestingHR
        let liveStrain = StrainScorer.strain(todayHR, maxHR: maxHR, restingHR: restHR,
                                             method: PuffinExperiment.effortMethod, sex: profile.sex)

        var nightHR: [HRSample] = []
        if let s = lastNight {
            nightHR = await repo.hrSamples(from: s.effectiveStartTs, to: s.endTs, limit: 60_000)
        }
        let recentSessions = await repo.sleepSessions(from: nowSec - 14 * 86_400, to: nowSec, limit: 60)
        let coach = SleepCoach.make(days: days, sessions: recentSessions, age: profile.age)
        let health = HealthMonitor.make(days: days, anchor: anchor, isWhoop5: isWhoop5)

        derived = VitalDerived(days: days,
                               anchor: anchor,
                               restScore: restScore,
                               lastNight: lastNight,
                               lastNightHR: nightHR,
                               todayHR: todayHR,
                               liveStrain: liveStrain,
                               computedAt: now,
                               importedDays: repo.freshness.importedDays,
                               computedDays: repo.freshness.computedDays,
                               sleepCoach: coach,
                               health: health)
        publishSnapshot()
        if VitalNotifications.morningRecoveryIfDue(anchor: anchor, todayKey: todayKey),
           VitalHaptics.enabled(VitalHaptics.morningBuzzKey) {
            buzz(loops: 2)
        }
        await reloadWorkouts()
    }

    /// Glance for the widget extension. Runs from the derived tick (≤ 1/min), NOOP's precedent for
    /// anything outside the foreground; `VitalSnapshot.publish` skips the WidgetKit reload when nothing
    /// rendered changed.
    private func publishSnapshot() {
        let a = derived.anchor
        VitalSnapshot.publish(VitalSnapshot(
            recovery: a?.recovery,
            strain: a?.strain ?? derived.liveStrain,
            rest: derived.restScore,
            hrv: a?.avgHrv,
            restingHr: a?.restingHr,
            bpm: bpm ?? live.heartRate,
            batteryPct: live.batteryPct.map { Int($0.rounded()) },
            connected: live.connected,
            dayKey: a?.day))
    }

    // MARK: Import

    /// First-run seed: the WHOOP export bundled at build time (`Vital/Seed/whoop_export.zip`, kept out of
    /// git). Recovery needs baseline history to score at all, so a fresh sandbox would otherwise show
    /// nothing for weeks.
    private func seedFromBundleIfNeeded() async {
        let key = "vital.seedImported"
        guard !UserDefaults.standard.bool(forKey: key),
              let url = Bundle.main.url(forResource: "whoop_export", withExtension: "zip") else { return }
        await importWhoopExport(from: url, runScoring: false)
        if case .done = importStatus { UserDefaults.standard.set(true, forKey: key) }
    }

    /// Import a WHOOP CSV export (`.zip` or folder) under the strap's device id, then re-score.
    func importWhoopExport(from url: URL, runScoring: Bool = true) async {
        importStatus = .importing
        guard let store = await repo.storeHandle() else {
            importStatus = .failed("Store not ready")
            return
        }
        do {
            let summary = try await WhoopImporter.importExport(url: url, into: store, deviceId: Self.deviceId)
            try? await store.checkpointWAL()
            await repo.refresh()
            metricCache.invalidate()
            await recomputeDerived()
            importStatus = .done(cycles: summary.countsByCategory["cycles"] ?? 0,
                                 sleeps: summary.countsByCategory["sleeps"] ?? 0,
                                 workouts: summary.countsByCategory["workouts"] ?? 0,
                                 at: Date())
            if runScoring { await self.runScoring(force: true, skipIfUnchanged: false) }
        } catch {
            importStatus = .failed(error.localizedDescription)
        }
    }

    /// Import from a user-picked file URL (security-scoped). Copies into the sandbox first so the
    /// importer can open the archive after the scope closes.
    func importPickedFile(_ picked: URL) async {
        let scoped = picked.startAccessingSecurityScopedResource()
        defer { if scoped { picked.stopAccessingSecurityScopedResource() } }
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("vital-import-\(UUID().uuidString)")
            .appendingPathExtension(picked.pathExtension.isEmpty ? "zip" : picked.pathExtension)
        do {
            try? FileManager.default.removeItem(at: tmp)
            try FileManager.default.copyItem(at: picked, to: tmp)
        } catch {
            importStatus = .failed("Could not read the file: \(error.localizedDescription)")
            return
        }
        defer { try? FileManager.default.removeItem(at: tmp) }
        await importWhoopExport(from: tmp)
    }
}

// MARK: - Value types the views consume

struct VitalSync: Equatable {
    var lastSyncedAt: Date?
    var backfilling = false
    var chunksThisSession = 0
}

struct VitalDerived {
    var days: [DailyMetric] = []
    /// The day the headline scores describe: today when scored, else the freshest strictly-prior scored day.
    var anchor: DailyMetric?
    var restScore: Double?
    var lastNight: CachedSleepSession?
    var lastNightHR: [HRSample] = []
    var todayHR: [HRSample] = []
    /// Strain accrued so far today from the HR already banked on-device (0–100 Effort axis).
    var liveStrain: Double?
    var computedAt: Date?
    var importedDays = 0
    var computedDays = 0
    var sleepCoach: SleepCoach?
    var health: HealthMonitor?

    var hasHistory: Bool { !days.isEmpty }
}

enum VitalImportStatus: Equatable {
    case idle
    case importing
    case done(cycles: Int, sleeps: Int, workouts: Int, at: Date)
    case failed(String)
}

// MARK: - Local notifications (no server)

enum VitalNotifications {
    static let morningAlertKey = "vital.morningAlert"
    private static let lastNotifiedDayKey = "vital.morningAlert.lastDay"

    /// Ask once; the Settings toggle drives this.
    static func requestPermission() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
    }

    /// Fire "your recovery is in" the first time today's score exists, once per day, only if enabled.
    /// Runs from the derived tick, so it lands minutes after the morning offload is scored.
    @discardableResult
    static func morningRecoveryIfDue(anchor: DailyMetric?, todayKey: String) -> Bool {
        let d = UserDefaults.standard
        guard let anchor, anchor.day == todayKey, let r = anchor.recovery,
              d.string(forKey: lastNotifiedDayKey) != todayKey else { return false }
        d.set(todayKey, forKey: lastNotifiedDayKey)
        guard d.bool(forKey: morningAlertKey) else { return true }
        let content = UNMutableNotificationContent()
        let pct = Int(r.rounded())
        content.title = "Recovery \(pct)%"
        switch VitalBand.recovery(r) {
        case .low: content.body = "Your body is asking for an easy day."
        case .mid: content.body = "Ready for a moderate day."
        case .high: content.body = "Well recovered. Good day to push."
        }
        if let hrv = anchor.avgHrv, let rhr = anchor.restingHr {
            content.subtitle = "HRV \(Int(hrv.rounded())) ms · RHR \(rhr) bpm"
        }
        content.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "vital.morning.\(todayKey)", content: content, trigger: nil))
        return true
    }
}

/// WHOOP-style strain coach: a target strain band for the day from the recovery band. Vital's own
/// mapping (display guidance, not a NOOP score): recovered → push, moderate → maintain, low → rest.
struct StrainCoach: Equatable {
    let recovery: Double
    let band: VitalBand
    /// On WHOOP's 0–21 scale.
    let targetRange: ClosedRange<Double>
    let headline: String

    init?(recovery: Double?) {
        guard let recovery else { return nil }
        self.recovery = recovery
        band = VitalBand.recovery(recovery)
        switch band {
        case .high: targetRange = 14.0...18.0; headline = "Push today"
        case .mid: targetRange = 10.0...14.0; headline = "Moderate day"
        case .low: targetRange = 4.0...9.0; headline = "Take it easy"
        }
    }
}
