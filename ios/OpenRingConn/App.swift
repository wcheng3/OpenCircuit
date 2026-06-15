import SwiftUI
import SwiftData

@main
struct OpenRingConnApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private let container = OpenRingConnApp.makeContainer()

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(container)
    }

    /// Build the SwiftData container, recovering from an incompatible on-disk store.
    ///
    /// The default `.modelContainer(for:)` modifier traps if the container can't be
    /// created — e.g. a schema change that lightweight migration can't handle — so the
    /// app dies on the launch screen (black screen). Instead, if the first attempt
    /// fails we wipe the local store and retry: it's only a cache of metrics the ring
    /// re-syncs (and that are already in Apple Health), so nothing is permanently lost.
    /// Prefer a real `SchemaMigrationPlan` for *expected* migrations; this is the
    /// last-resort net so a model change can never hard-crash launch again.
    static func makeContainer() -> ModelContainer {
        let schema = Schema([StoredSample.self, StoredCursor.self,
                             StoredSleepSummary.self, StoredDaily.self])
        let config = ModelConfiguration(schema: schema)

        do {
            return try ModelContainer(for: schema, configurations: config)
        } catch {
            #if DEBUG
            print("SwiftData store unusable (\(error)); resetting local cache and retrying.")
            #endif
            removeStoreFiles(at: config.url)
            do {
                return try ModelContainer(for: schema, configurations: config)
            } catch {
                // A fresh store still failed — genuinely unrecoverable (e.g. no disk).
                fatalError("Unrecoverable SwiftData store error: \(error)")
            }
        }
    }

    /// Delete the SQLite store plus its `-shm`/`-wal` sidecar files.
    private static func removeStoreFiles(at storeURL: URL) {
        let fm = FileManager.default
        let base = storeURL.deletingPathExtension()
        for url in [storeURL,
                    base.appendingPathExtension("store-shm"),
                    base.appendingPathExtension("store-wal")] {
            try? fm.removeItem(at: url)
        }
    }
}
