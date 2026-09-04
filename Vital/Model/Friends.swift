import Foundation
import WhoopStore

/// A friend's (or your own) shareable stats card. Travels as a `vital://friend?d=<base64url JSON>` link
/// pasted into iMessage; tapping it opens Vital and files the card. No server, no account: the "network"
/// is the group chat. Every field is optional so people can share only what they want.
struct FriendCard: Codable, Equatable, Identifiable {
    var name: String
    var dayKey: String?
    var recovery: Int?
    /// Strain on WHOOP's 0–21 scale (one decimal).
    var strain: Double?
    var sleepPct: Int?
    var hrv: Int?
    var rhr: Int?
    var sleepMin: Double?
    var weekRecovery: Int?
    var weekStrain: Double?
    var weekSleepMin: Double?
    var updated: Date

    var id: String { name.lowercased() }

    // MARK: Link encoding

    static let scheme = "vital"
    static let host = "friend"

    func link() -> URL? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        let b64 = data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return URL(string: "\(Self.scheme)://\(Self.host)?d=\(b64)")
    }

    static func decode(_ url: URL) -> FriendCard? {
        guard url.scheme == scheme, url.host == host,
              let q = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let raw = q.first(where: { $0.name == "d" })?.value else { return nil }
        return decode(code: raw)
    }

    /// Also accepts the bare code (what's left after `d=`) pasted by hand.
    static func decode(code raw: String) -> FriendCard? {
        var b64 = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let r = b64.range(of: "d=") { b64 = String(b64[r.upperBound...]) }
        b64 = b64.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64) else { return nil }
        return try? JSONDecoder().decode(FriendCard.self, from: data)
    }

    /// The message text that accompanies the link, readable even without the app.
    func summaryText() -> String {
        var parts: [String] = []
        if let r = recovery { parts.append("Recovery \(r)%") }
        if let s = strain { parts.append(String(format: "Strain %.1f", s)) }
        if let s = sleepPct { parts.append("Sleep \(s)%") }
        if let h = hrv { parts.append("HRV \(h) ms") }
        if let r = rhr { parts.append("RHR \(r)") }
        let day = dayKey.map(VFormat.dayLabel) ?? "today"
        return "\(name) · \(day): " + (parts.isEmpty ? "stats" : parts.joined(separator: " · "))
    }
}

/// Which of your fields go into the card you share.
enum ShareFields {
    static let key = "vital.share.fields"
    static let all = ["recovery", "strain", "sleep", "hrv", "rhr", "week"]
    static var included: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: key) ?? ["recovery", "strain", "sleep", "week"]) }
        set { UserDefaults.standard.set(Array(newValue).sorted(), forKey: key) }
    }
    static let nameKey = "vital.share.name"
    static var name: String {
        get { UserDefaults.standard.string(forKey: nameKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: nameKey) }
    }
}

/// Local roster of friends' latest cards. A new card from the same name replaces the old one.
@MainActor
final class FriendsStore: ObservableObject {
    static let key = "vital.friends"
    @Published private(set) var friends: [FriendCard] = []

    init() { load() }

    func upsert(_ card: FriendCard) {
        friends.removeAll { $0.id == card.id }
        friends.append(card)
        friends.sort { $0.name.lowercased() < $1.name.lowercased() }
        save()
    }

    func remove(_ card: FriendCard) {
        friends.removeAll { $0.id == card.id }
        save()
    }

    private func load() {
        guard let d = UserDefaults.standard.data(forKey: Self.key),
              let list = try? JSONDecoder().decode([FriendCard].self, from: d) else { return }
        friends = list
    }

    private func save() {
        if let d = try? JSONEncoder().encode(friends) { UserDefaults.standard.set(d, forKey: Self.key) }
    }
}

/// Leaderboard categories. `higherIsBetter` decides sort order; RHR is the one where lower wins.
enum LeaderCategory: String, CaseIterable, Identifiable {
    case recovery, strain, sleep, hrv, rhr, weekRecovery, weekStrain, weekSleep
    var id: String { rawValue }

    var label: String {
        switch self {
        case .recovery: return "Recovery"
        case .strain: return "Strain"
        case .sleep: return "Sleep"
        case .hrv: return "HRV"
        case .rhr: return "Resting HR"
        case .weekRecovery: return "7-day recovery"
        case .weekStrain: return "7-day strain"
        case .weekSleep: return "7-day sleep"
        }
    }

    var higherIsBetter: Bool { self != .rhr }

    func value(_ c: FriendCard) -> Double? {
        switch self {
        case .recovery: return c.recovery.map(Double.init)
        case .strain: return c.strain
        case .sleep: return c.sleepPct.map(Double.init)
        case .hrv: return c.hrv.map(Double.init)
        case .rhr: return c.rhr.map(Double.init)
        case .weekRecovery: return c.weekRecovery.map(Double.init)
        case .weekStrain: return c.weekStrain
        case .weekSleep: return c.weekSleepMin.map { $0 / 60 }
        }
    }

    func format(_ v: Double) -> String {
        switch self {
        case .recovery, .sleep, .weekRecovery: return "\(Int(v.rounded()))%"
        case .strain, .weekStrain: return String(format: "%.1f", v)
        case .hrv: return "\(Int(v.rounded())) ms"
        case .rhr: return "\(Int(v.rounded())) bpm"
        case .weekSleep: return String(format: "%.1f h", v)
        }
    }
}

@MainActor
extension VitalModel {
    /// Your own card from the current derived state, filtered to the fields you chose to share.
    func myCard() -> FriendCard {
        let inc = ShareFields.included
        let a = derived.anchor
        let last7 = derived.days.suffix(7)
        func avg(_ xs: [Double]) -> Double? { xs.isEmpty ? nil : xs.reduce(0, +) / Double(xs.count) }
        let name = ShareFields.name.isEmpty ? "Me" : ShareFields.name
        return FriendCard(
            name: name,
            dayKey: a?.day,
            recovery: inc.contains("recovery") ? a?.recovery.map { Int($0.rounded()) } : nil,
            strain: inc.contains("strain") ? (a?.strain ?? derived.liveStrain).map { ($0 * 21 / 100 * 10).rounded() / 10 } : nil,
            sleepPct: inc.contains("sleep") ? derived.restScore.map { Int($0.rounded()) } : nil,
            hrv: inc.contains("hrv") ? a?.avgHrv.map { Int($0.rounded()) } : nil,
            rhr: inc.contains("rhr") ? a?.restingHr : nil,
            sleepMin: inc.contains("sleep") ? a?.totalSleepMin : nil,
            weekRecovery: inc.contains("week") ? avg(last7.compactMap(\.recovery)).map { Int($0.rounded()) } : nil,
            weekStrain: inc.contains("week") ? avg(last7.compactMap(\.strain)).map { ($0 * 21 / 100 * 10).rounded() / 10 } : nil,
            weekSleepMin: inc.contains("week") ? avg(last7.compactMap(\.totalSleepMin)) : nil,
            updated: Date())
    }
}
