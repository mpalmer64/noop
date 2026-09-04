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
// AppModel.postInactivity(minutes:)       Strand/App/AppModel.swift          BLEManager (sedentary
//                                                                            detector → local notification)
// AppleHealthLoadCache                    Strand/Screens/AppleHealthView.swift   Repository (load cache)
// InsightsLoadCache                       Strand/Screens/InsightsView.swift      Repository (load cache)
// TodayDayScopedCache                     Strand/Screens/TodayView.swift         Repository (load cache)
// TodayHistoryWideCache                   Strand/Screens/TodayView.swift         Repository (load cache)
// AvatarImage.downscaledJPEG              Strand/Screens/ProfileAvatarView.swift ProfileStore (avatar set)
//
// The three *LoadCache structs are plain value types whose shape must match upstream field-for-field
// (Repository constructs them). Vital never reads them; they exist so Repository compiles.
// IntelligenceEngine is the REAL upstream file since Phase 2 (option (a)); no shim for it here.

import Foundation
import ImageIO
import StrandAnalytics
import StrandDesign
import UserNotifications
import WhoopStore

/// Stand-in for NOOP's `AppChangelog`. BLEManager compares this against a persisted key so a
/// per-version one-shot (a firmware-flag replay) runs once per app version. Vital's own marketing
/// version is the right key for that, so the one-shot fires once per Vital release.
enum AppChangelog {
    static let currentVersion: String =
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0"
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

// MARK: Repository load caches (shape must track upstream; see header)

/// Twin of `AppleHealthLoadCache` in Strand/Screens/AppleHealthView.swift.
struct AppleHealthLoadCache {
    let appleRows: [AppleDaily]
    let workoutCount: Int
    let series: [String: [(day: String, value: Double)]]
}

/// Twin of `InsightsLoadCache` in Strand/Screens/InsightsView.swift.
struct InsightsLoadCache {
    let behaviours: [String: Set<String>]
    let controls: [String: Set<String>]
    let importedQuestions: [String]
    let dayAnswers: [String: Bool]
    let journalDayOffset: Int
    let outcomeByKey: [String: [String: Double]]
    let seriesByKey: [String: [(day: String, value: Double)]]
    let activityCosts: [ActivityCost]
    let numericJournalByKey: [String: [String: Double]]
}

/// Twin of `TodayDayScopedCache` in Strand/Screens/TodayView.swift.
struct TodayDayScopedCache {
    let restSpark: [Double]
    let restScore: Double?
    let provenanceByMetric: [String: String]
    let providerByMetric: [String: ScoreInputProvider]
    let hrPoints: [TrendPoint]
    let stepActivityClassToday: Int?
    let liveTodayStrain: Double?
    let hrAxis: ClosedRange<Date>
    let sleepToday: CachedSleepSession?
    let bankedAt: Date
}

/// Twin of `TodayHistoryWideCache` in Strand/Screens/TodayView.swift.
struct TodayHistoryWideCache {
    let sparks: [String: [Double]]
    let stepsEstByDay: [String: Int]
    let workouts: [WorkoutRow]
    let appleDays: [AppleDaily]
    let xiaomiDays: Int
    let xiaomiSleeps: Int
    let stressToday: Double?
    let fitnessAgeToday: Double?
    let vo2maxToday: Double?
    let vitalityToday: Double?
}

// MARK: Avatar helper

/// Stand-in for `AvatarImage` in Strand/Screens/ProfileAvatarView.swift: ProfileStore downsizes a picked
/// avatar before persisting it. Same contract (thumbnail ≤ maxDimension, EXIF orientation honoured,
/// JPEG at `quality`), independently written against ImageIO.
enum AvatarImage {
    static func downscaledJPEG(from data: Data, maxDimension: CGFloat = 256, quality: CGFloat = 0.8) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(maxDimension),
        ]
        guard let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, thumb, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }
}
