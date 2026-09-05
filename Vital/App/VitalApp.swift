import SwiftUI
import WhoopStore

@main
struct VitalApp: App {
    @StateObject private var model = VitalModel()
    @StateObject private var friends = FriendsStore()
    @AppStorage(VitalAppearance.key) private var appearance: VitalAppearance = .dark

    var body: some Scene {
        WindowGroup {
            VitalRootView()
                .environmentObject(model)
                .environmentObject(friends)
                .preferredColorScheme(appearance.colorScheme)
                .task { await model.start() }
                // A friend's `vital://friend?d=…` link tapped in iMessage lands here.
                .onOpenURL { url in
                    if let card = FriendCard.decode(url) { friends.upsert(card) }
                }
        }
    }
}

struct VitalRootView: View {
    @EnvironmentObject private var model: VitalModel
    /// Debug affordance: `VITAL_TAB=today|sleep|trends` in the launch environment preselects a tab so a
    /// headless simulator run can screenshot every screen. Inert in normal use.
    @State private var tab: Tab = Tab(rawValue: ProcessInfo.processInfo.environment["VITAL_TAB"] ?? "") ?? .now
    @State private var showSettings = ProcessInfo.processInfo.environment["VITAL_TAB"] == "settings"
    @State private var showFriends = ProcessInfo.processInfo.environment["VITAL_TAB"] == "friends"
    @State private var showJournal = ProcessInfo.processInfo.environment["VITAL_TAB"] == "journal"
    /// Debug affordance, same spirit as `VITAL_TAB`: `VITAL_DETAIL=recovery|hr|…|nights|night` opens a
    /// drill-down screen directly so a headless run can screenshot it. Inert in normal use.
    @State private var debugDetail: DebugKey? = ProcessInfo.processInfo.environment["VITAL_DETAIL"].map(DebugKey.init)
    struct DebugKey: Identifiable { let id: String }

    enum Tab: String { case now, today, sleep, activity, trends }

    var body: some View {
        TabView(selection: $tab) {
            NavigationStack { NowScreen(live: model.live) }
                .tabItem { Label("Now", systemImage: "heart.fill") }.tag(Tab.now)
            NavigationStack { TodayScreen() }
                .tabItem { Label("Today", systemImage: "circle.circle") }.tag(Tab.today)
            NavigationStack { SleepScreen() }
                .tabItem { Label("Sleep", systemImage: "moon.zzz.fill") }.tag(Tab.sleep)
            NavigationStack { ActivitiesScreen() }
                .tabItem { Label("Activity", systemImage: "figure.run") }.tag(Tab.activity)
            NavigationStack { TrendsScreen() }
                .tabItem { Label("Trends", systemImage: "chart.xyaxis.line") }.tag(Tab.trends)
        }
        .tint(VColor.textPrimary)
        .sheet(isPresented: $showSettings) { SettingsScreen() }
        .sheet(isPresented: $showFriends) { NavigationStack { LeaderboardScreen() } }
        .sheet(isPresented: $showJournal) { JournalInsightsSheet() }
        .sheet(item: $debugDetail) { key in NavigationStack { debugDetailView(key.id) } }
    }

    @ViewBuilder
    private func debugDetailView(_ key: String) -> some View {
        let parts = key.split(separator: "@").map(String.init)
        let name = parts.first ?? key
        let range = parts.count > 1 ? TimeRange(rawValue: parts[1]) : nil
        if name == "nights" {
            NightsListScreen()
        } else if name == "night" {
            LatestNightDebugView()
        } else if let id = MetricID(rawValue: name) {
            DebugMetricView(id: id, range: range)
        } else {
            Text("Unknown VITAL_DETAIL \(key)")
        }
    }
}

/// Dark is the default look (OLED black canvas); System and Light are one tap away in Settings.
enum VitalAppearance: String, CaseIterable, Identifiable {
    case dark, system, light
    static let key = "vital.appearance"
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
    var colorScheme: ColorScheme? {
        switch self {
        case .dark: return .dark
        case .light: return .light
        case .system: return nil
        }
    }
}

/// Debug-only: the most recent night on record (the seed export has no "last 24 h" night).
private struct LatestNightDebugView: View {
    @EnvironmentObject private var model: VitalModel
    @State private var night: CachedSleepSession?
    var body: some View {
        Group {
            if let night { NightDetailView(night: night) } else { ProgressView() }
        }
        .task { night = await model.repo.allSleepSessions(days: 4000).last }
    }
}

/// Debug-only: waits for the first scoring pass so the anchor day exists, then opens the metric on it.
private struct DebugMetricView: View {
    @EnvironmentObject private var model: VitalModel
    let id: MetricID
    let range: TimeRange?
    var body: some View {
        if let anchor = model.derived.anchor?.day {
            MetricDetailView(id: id, dayKey: range == nil ? anchor : nil, initialRange: range)
        } else {
            ProgressView()
        }
    }
}
