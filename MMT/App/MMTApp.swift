import SwiftUI

@main
struct MMTApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}

struct RootView: View {
    @State private var tracker = DirectionTracker()

    var body: some View {
        TabView {
            Tab("Camera", systemImage: "camera.viewfinder") {
                ARDirectionView(tracker: tracker)
            }
            Tab("Debug", systemImage: "waveform") {
                DirectionDebugView(tracker: tracker)
            }
        }
        .task { await tracker.run() }
    }
}
