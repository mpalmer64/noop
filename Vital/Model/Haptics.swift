import Foundation
import UserNotifications
import WhoopProtocol

/// Everything that makes the strap buzz. Each is a preference the user can turn off; nothing buzzes unless
/// the strap is bonded. Commands are the ones NOOP already sends (`runHapticsPattern`, the firmware alarm).
enum VitalHaptics {
    static let moveReminderKey = "vital.haptics.move"        // BLE sedentary detector → buzz + notification
    static let zoneCoachingKey = "vital.haptics.zones"       // during an activity: enter zone 5 / drop to zone 1
    static let hapticClockKey = "vital.haptics.clock"        // double-tap the strap → it taps the time back
    static let morningBuzzKey = "vital.haptics.morning"      // today's recovery landed
    static let strainTargetKey = "vital.haptics.strainTarget" // strain coach target reached
    static let alarmEnabledKey = "vital.alarm.enabled"
    static let alarmMinutesKey = "vital.alarm.minutes"       // minutes after midnight
    static let windDownEnabledKey = "vital.winddown.enabled"
    static let windDownMinutesKey = "vital.winddown.minutes" // minutes after midnight, the "in bed by" time
    /// "simple" (default): hour as single buzzes, pause, one double-buzz per quarter hour.
    /// "digits": NOOP's encoder (long = tens, short = units, hour then minute).
    static let clockStyleKey = "vital.haptics.clockStyle"
    static var clockStyle: String { UserDefaults.standard.string(forKey: clockStyleKey) ?? "simple" }

    static func enabled(_ key: String, default def: Bool = true) -> Bool {
        (UserDefaults.standard.object(forKey: key) as? Bool) ?? def
    }
    static var alarmMinutes: Int {
        let v = UserDefaults.standard.integer(forKey: alarmMinutesKey)
        return v > 0 ? v : 7 * 60
    }
    static var windDownMinutes: Int {
        let v = UserDefaults.standard.integer(forKey: windDownMinutesKey)
        return v > 0 ? v : 22 * 60 + 30
    }

    /// Next occurrence of a minutes-after-midnight time (NOOP's `nextSmartAlarmDate`, every day).
    static func nextDate(minutes: Int, from now: Date = Date()) -> Date? {
        let cal = Calendar.current
        for offset in 0...1 {
            guard let day = cal.date(byAdding: .day, value: offset, to: now),
                  let fire = cal.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: day),
                  fire > now else { continue }
            return fire
        }
        return nil
    }
}

@MainActor
extension VitalModel {

    /// One haptic burst. `loops` 1–3 is the vocabulary NOOP uses (1 = ack, 2 = done, 3 = ease off).
    func buzz(loops: UInt8) {
        guard live.bonded else { return }
        ble.send(.runHapticsPattern, payload: [2, loops, 0, 0, 0])
    }

    func buzz(loops: UInt8, gate: String) {
        if HapticPrefs.enabled(gate) { buzz(loops: loops) }
    }

    /// Zone coaching, NOOP's rule: buzz 3 on entering zone 5 (ease off), buzz 1 on dropping to zone 1 or
    /// below (recovered). Vital only coaches during an activity so a stair climb never buzzes you.
    func coachZone(_ hr: Int?) {
        guard activity != nil, VitalHaptics.enabled(VitalHaptics.zoneCoachingKey),
              live.bonded, let hr, hr >= 30, profile.hrMax > 0 else { return }
        let zone = profile.hrZoneSet.zoneNumber(forBPM: Double(hr))
        defer { lastCoachZone = zone }
        guard lastCoachZone != -1, zone != lastCoachZone else { return }
        if zone == 5, lastCoachZone < 5 { buzz(loops: 3) }
        else if zone <= 1, lastCoachZone > 1 { buzz(loops: 1) }
    }

    /// Strap-side wake alarm (firmware alarm, fires even if the phone is away) with a local notification as
    /// backup. Re-armed after every bond and just after midnight.
    func applyAlarm() {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: ["vital.alarm.backup"])
        guard VitalHaptics.enabled(VitalHaptics.alarmEnabledKey, default: false),
              let next = VitalHaptics.nextDate(minutes: VitalHaptics.alarmMinutes) else {
            if live.bonded { ble.disableStrapAlarm() }
            return
        }
        if live.bonded { ble.armStrapAlarm(at: next) }
        let content = UNMutableNotificationContent()
        content.title = "Good morning"
        content.body = "Your strap alarm was set for now."
        content.sound = .default
        let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: next)
        center.add(UNNotificationRequest(identifier: "vital.alarm.backup", content: content,
                                         trigger: UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)))
    }

    /// Wind-down: a nightly reminder 30 minutes before the chosen bedtime (notification), plus a buzz if the
    /// app happens to be alive at that minute.
    func applyWindDown() {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: ["vital.winddown"])
        guard VitalHaptics.enabled(VitalHaptics.windDownEnabledKey, default: false) else { return }
        let mins = (VitalHaptics.windDownMinutes - 30 + 1440) % 1440
        let content = UNMutableNotificationContent()
        content.title = "Wind down"
        content.body = "Bed in 30 minutes keeps tonight on track."
        content.sound = .default
        var comps = DateComponents(); comps.hour = mins / 60; comps.minute = mins % 60
        center.add(UNNotificationRequest(identifier: "vital.winddown", content: content,
                                         trigger: UNCalendarNotificationTrigger(dateMatching: comps, repeats: true)))
    }

    /// Called from the 60 s derived tick: buzz at the wind-down minute and when the strain target is reached.
    func hapticTick(now: Date = Date()) {
        let d = UserDefaults.standard
        let today = Repository.localDayKey(now)
        let minuteOfDay = Calendar.current.component(.hour, from: now) * 60 + Calendar.current.component(.minute, from: now)
        if VitalHaptics.enabled(VitalHaptics.windDownEnabledKey, default: false),
           minuteOfDay == (VitalHaptics.windDownMinutes - 30 + 1440) % 1440,
           d.string(forKey: "vital.winddown.lastDay") != today {
            d.set(today, forKey: "vital.winddown.lastDay")
            buzz(loops: 2)
        }
        if VitalHaptics.enabled(VitalHaptics.strainTargetKey),
           let live = derived.liveStrain, let target = strainCoach?.targetRange.upperBound,
           live * 21 / 100 >= target, d.string(forKey: "vital.strainTarget.lastDay") != today {
            d.set(today, forKey: "vital.strainTarget.lastDay")
            buzz(loops: 2)
        }
    }

    /// Double-tap on the strap taps the current time back.
    func handleDoubleTap() {
        guard VitalHaptics.enabled(VitalHaptics.hapticClockKey, default: false), live.bonded else { return }
        if VitalHaptics.clockStyle == "digits" {
            ble.buzzTimeNow(is24h: false)
        } else {
            buzzTimeSimple()
        }
    }

    /// Simple haptic clock: N single buzzes for the 12-hour hour (12 for twelve), a long pause, then one
    /// double-buzz per completed quarter hour (0–3). 4:35 → ·4 singles· pause ·2 doubles·. Nothing to
    /// decode, and it never relies on telling a long buzz from a short one.
    func buzzTimeSimple(at date: Date = Date()) {
        let comps = Calendar.current.dateComponents([.hour, .minute], from: date)
        let h24 = comps.hour ?? 0
        let hour12 = h24 % 12 == 0 ? 12 : h24 % 12
        let quarters = (comps.minute ?? 0) / 15
        var t = 0
        for _ in 0..<hour12 {
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(t)) { [weak self] in self?.buzz(loops: 1) }
            t += 800
        }
        t += 1200
        for _ in 0..<quarters {
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(t)) { [weak self] in self?.buzz(loops: 2) }
            t += 1300
        }
        live.append(log: "Haptic clock (simple): \(hour12) hour buzz(es) + \(quarters) quarter double-buzz(es)")
    }
}
