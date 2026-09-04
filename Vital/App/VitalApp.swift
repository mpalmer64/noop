import SwiftUI

@main
struct VitalApp: App {
    @StateObject private var model = VitalModel()

    var body: some Scene {
        WindowGroup {
            NowView(live: model.live)
                .environmentObject(model)
        }
    }
}
