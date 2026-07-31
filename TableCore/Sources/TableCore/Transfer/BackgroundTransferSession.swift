import Foundation

/// The background `URLSession` of DESIGN §2: transfers that keep moving while the app is
/// suspended, and that the system hands back — relaunching the app if it has to — when they
/// finish.
///
/// One instance per identifier per process. `URLSession` refuses a second session with the
/// same background identifier, and it is this instance that the system delivers the events of
/// tasks started by *earlier* launches to, which is what makes conformance rule 14 work here:
/// the bytes land in the partial file whether or not anyone is waiting for them.
public final class BackgroundTransferSession: NSObject, FileDownloadTransport, FileBodyTransport, @unchecked Sendable {
    private enum TaskOutcome: Sendable {
        case downloaded(bytesOnDisk: Int64)
        case answered(Data, HTTPURLResponse)
    }

    private let lock = NSLock()
    private var waiting: [String: CheckedContinuation<TaskOutcome, Error>] = [:]

    /// Outcomes of tasks that finished with nobody waiting — the relaunch case.
    private var delivered: [String: Result<TaskOutcome, Error>] = [:]

    private var progressReports: [String: @Sendable (Int64) -> Void] = [:]
    private var collectedBody: [String: Data] = [:]
    private var appendedTail: [String: Result<Int64, Error>] = [:]
    private var session: URLSession!

    public init(identifier: String, sharedContainerIdentifier: String? = nil) {
        super.init()
        let configuration = URLSessionConfiguration.background(withIdentifier: identifier)
        // Somebody is waiting for this file, so it does not get to wait for a charger.
        configuration.isDiscretionary = false
        configuration.timeoutIntervalForRequest = transferInactivityTimeout
        configuration.sharedContainerIdentifier = sharedContainerIdentifier
        #if os(iOS)
        configuration.sessionSendsLaunchEvents = true
        #endif
        let events = OperationQueue()
        // Serial: the ordering the delivered/waiting handover relies on, and what lets
        // `allTasks` see every event that was queued before it.
        events.maxConcurrentOperationCount = 1
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: events)
    }

    public func download(
        _ request: URLRequest,
        plan: BackgroundDownloadPlan,
        taskID: String,
        onProgress: (@Sendable (Int64) -> Void)?
    ) async throws -> Int64 {
        let session = session!
        let outcome = try await run(taskID, onProgress: onProgress) {
            let task = session.downloadTask(with: request)
            task.taskDescription = BackgroundTaskLabel(taskID: taskID, plan: plan).encoded
            return task
        }
        guard case .downloaded(let bytesOnDisk) = outcome else {
            throw TableError.malformedResponse("background download \(taskID) came back as an upload")
        }
        return bytesOnDisk
    }

    public func send(
        _ request: URLRequest,
        bodyFile: URL,
        taskID: String,
        onProgress: (@Sendable (Int64) -> Void)?
    ) async throws -> (Data, HTTPURLResponse) {
        let session = session!
        let outcome = try await run(taskID, onProgress: onProgress) {
            let task = session.uploadTask(with: request, fromFile: bodyFile)
            task.taskDescription = BackgroundTaskLabel(taskID: taskID).encoded
            return task
        }
        guard case .answered(let data, let response) = outcome else {
            throw TableError.malformedResponse("background upload \(taskID) came back as a download")
        }
        return (data, response)
    }

    /// Waits for `taskID`, adopting the task an earlier launch started rather than sending the
    /// same bytes twice.
    private func run(
        _ taskID: String,
        onProgress: (@Sendable (Int64) -> Void)?,
        start: @escaping @Sendable () -> URLSessionTask
    ) async throws -> TaskOutcome {
        lock.withLock { progressReports[taskID] = onProgress }
        defer { lock.withLock { progressReports[taskID] = nil } }

        let alreadyRunning = await outstandingTask(taskID)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if let ready = delivered.removeValue(forKey: taskID) {
                    lock.unlock()
                    continuation.resume(with: ready)
                    return
                }
                waiting[taskID] = continuation
                lock.unlock()
                (alreadyRunning ?? start()).resume()
            }
        } onCancel: {
            abandon(taskID)
        }
    }

    private func outstandingTask(_ taskID: String) async -> URLSessionTask? {
        await session.allTasks.first {
            $0.state != .completed && BackgroundTaskLabel($0.taskDescription)?.taskID == taskID
        }
    }

    private func abandon(_ taskID: String) {
        let waiter = lock.withLock { waiting.removeValue(forKey: taskID) }
        waiter?.resume(throwing: CancellationError())
        Task { await outstandingTask(taskID)?.cancel() }
    }

    private func finish(_ taskID: String, _ outcome: Result<TaskOutcome, Error>) {
        let waiter: CheckedContinuation<TaskOutcome, Error>? = lock.withLock {
            collectedBody[taskID] = nil
            appendedTail[taskID] = nil
            guard let waiter = waiting.removeValue(forKey: taskID) else {
                // A cancelled task tells the next attempt nothing it should act on.
                if !isCancellation(outcome) {
                    delivered[taskID] = outcome
                }
                return nil
            }
            return waiter
        }
        waiter?.resume(with: outcome)
    }
}

extension BackgroundTransferSession: URLSessionDownloadDelegate {
    /// The delivered file is gone when this returns, so the tail is appended here rather than
    /// handed to a caller who may not exist.
    public func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let label = BackgroundTaskLabel(downloadTask.taskDescription), let plan = label.plan else { return }
        let appended = Result {
            guard let http = downloadTask.response as? HTTPURLResponse else {
                throw TableError.malformedResponse("download \(plan.fileID) arrived without an HTTP response")
            }
            return try applyDownloadedTail(location, DownloadHeaders(http), to: plan)
        }
        lock.withLock { appendedTail[label.taskID] = appended }
    }

    public func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        report(totalBytesWritten, of: downloadTask)
    }

    public func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        report(totalBytesSent, of: task)
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let label = BackgroundTaskLabel(task.taskDescription) else { return }
        finish(label.taskID, label.plan == nil ? answer(of: task, error) : tail(of: label.taskID, error))
    }

    private func tail(of taskID: String, _ error: Error?) -> Result<TaskOutcome, Error> {
        switch (lock.withLock { appendedTail[taskID] }, error) {
        case (.success(let bytesOnDisk), _):
            return .success(.downloaded(bytesOnDisk: bytesOnDisk))
        // What the tail could not be applied for — a gone file, a hole, a bad declaration —
        // says more than the transport error that may accompany it.
        case (.failure(let reason), _):
            return .failure(reason)
        case (nil, let transportFailure?):
            return .failure(transportFailure)
        case (nil, nil):
            return .failure(TableError.malformedResponse("background download \(taskID) delivered no file"))
        }
    }

    private func answer(of task: URLSessionTask, _ error: Error?) -> Result<TaskOutcome, Error> {
        guard let label = BackgroundTaskLabel(task.taskDescription) else {
            return .failure(TableError.malformedResponse("a background upload finished unlabelled"))
        }
        if let error {
            return .failure(error)
        }
        guard let http = task.response as? HTTPURLResponse else {
            return .failure(TableError.malformedResponse("upload \(label.taskID) finished without an HTTP response"))
        }
        return .success(.answered(lock.withLock { collectedBody[label.taskID] } ?? Data(), http))
    }

    private func report(_ bytes: Int64, of task: URLSessionTask) {
        guard let label = BackgroundTaskLabel(task.taskDescription) else { return }
        lock.withLock { progressReports[label.taskID] }?(bytes)
    }
}

extension BackgroundTransferSession: URLSessionDataDelegate {
    /// An upload task is a data task, and `PATCH` answers with the file it finalized.
    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let label = BackgroundTaskLabel(dataTask.taskDescription) else { return }
        lock.withLock { collectedBody[label.taskID, default: Data()].append(data) }
    }
}

/// What a background task carries across process death: `taskDescription` is the only state
/// the system keeps for us.
struct BackgroundTaskLabel: Codable, Sendable {
    let taskID: String

    /// Downloads only: where the bytes go and what the server has to declare (rule 6).
    let plan: BackgroundDownloadPlan?

    init(taskID: String, plan: BackgroundDownloadPlan? = nil) {
        self.taskID = taskID
        self.plan = plan
    }

    init?(_ taskDescription: String?) {
        guard let encoded = taskDescription?.data(using: .utf8),
              let label = try? JSONDecoder().decode(Self.self, from: encoded)
        else { return nil }
        self = label
    }

    var encoded: String? {
        (try? JSONEncoder().encode(self)).flatMap { String(data: $0, encoding: .utf8) }
    }
}

private func isCancellation(_ outcome: Result<some Sendable, Error>) -> Bool {
    guard case .failure(let error) = outcome else { return false }
    return error is CancellationError || (error as? URLError)?.code == .cancelled
}
