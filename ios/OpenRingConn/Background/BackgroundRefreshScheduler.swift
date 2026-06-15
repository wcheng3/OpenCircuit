import BackgroundTasks
import Foundation

protocol BGTaskScheduling {
    func register(forTaskWithIdentifier identifier: String,
                  using queue: DispatchQueue?,
                  launchHandler: @escaping (BGTask) -> Void) -> Bool
    func cancel(taskRequestWithIdentifier identifier: String)
    func submit(_ taskRequest: BGTaskRequest) throws
}

extension BGTaskScheduler: BGTaskScheduling {}

struct BackgroundRefreshScheduler {
    static let identifier = "com.openringconn.app.bgrefresh"
    static let refreshInterval: TimeInterval = 15 * 60

    private let scheduler: BGTaskScheduling
    private let now: () -> Date

    init(scheduler: BGTaskScheduling = BGTaskScheduler.shared,
         now: @escaping () -> Date = Date.init) {
        self.scheduler = scheduler
        self.now = now
    }

    @discardableResult
    func register(launchHandler: @escaping (BGTask) -> Void) -> Bool {
        scheduler.register(
            forTaskWithIdentifier: Self.identifier,
            using: nil,
            launchHandler: launchHandler
        )
    }

    func makeRequest() -> BGAppRefreshTaskRequest {
        let request = BGAppRefreshTaskRequest(identifier: Self.identifier)
        request.earliestBeginDate = now().addingTimeInterval(Self.refreshInterval)
        return request
    }

    func schedule() {
        do {
            scheduler.cancel(taskRequestWithIdentifier: Self.identifier)
            try scheduler.submit(makeRequest())
        } catch {
            #if DEBUG
            print("Unable to schedule background refresh: \(error)")
            #endif
        }
    }
}
