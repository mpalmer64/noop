import SwiftUI

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
