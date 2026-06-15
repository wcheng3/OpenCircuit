import SwiftUI
import SwiftData

@main
struct OpenRingConnApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(for: [StoredSample.self, StoredCursor.self])
    }
}
