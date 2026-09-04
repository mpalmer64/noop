import SwiftUI

@main
struct VitalApp: App {
    @StateObject private var model = VitalModel()

    var body: some Scene {
        WindowGroup {
            VitalRootView()
                .environmentObject(model)
                .task { await model.start() }
        }
    }
}

struct VitalRootView: View {
    @EnvironmentObject private var model: VitalModel

    var body: some View {
        TabView {
            NavigationStack { NowScreen(live: model.live) }
                .tabItem { Label("Now", systemImage: "heart.fill") }
            NavigationStack { TodayScreen() }
                .tabItem { Label("Today", systemImage: "circle.circle") }
            NavigationStack { SleepScreen() }
                .tabItem { Label("Sleep", systemImage: "moon.zzz.fill") }
            NavigationStack { TrendsScreen() }
                .tabItem { Label("Trends", systemImage: "chart.xyaxis.line") }
        }
        .tint(VColor.textPrimary)
    }
}
