import Foundation

/// A bounded hand-off of response-body chunks from the `URLSession` delegate queue to the
/// task consuming them.
///
/// Sending blocks while the buffer is full, which stops URLSession draining the socket —
/// the backpressure that keeps a multi-GB download O(buffer) in memory instead of racing
/// ahead of the disk. `@unchecked Sendable`: every field is guarded by `condition`.
final class BodyChannel: @unchecked Sendable {
    private let condition = NSCondition()
    private let capacity: Int
    private var buffered: [Data] = []
    private var waiter: CheckedContinuation<Data?, Error>?
    private var completion: Result<Void, Error>?
    private var terminated = false

    /// Runs when the consumer walks away, so the connection goes with it.
    private var onTerminate: (@Sendable () -> Void)?

    init(bufferedChunks: Int = 8) {
        capacity = bufferedChunks
    }

    func onTerminate(_ cancel: @escaping @Sendable () -> Void) {
        condition.lock()
        let alreadyTerminated = terminated
        onTerminate = cancel
        condition.unlock()
        if alreadyTerminated { cancel() }
    }

    /// Blocks the caller while the buffer is full; returns early once terminated.
    func send(_ data: Data) {
        condition.lock()
        while buffered.count >= capacity && !terminated {
            condition.wait()
        }
        if terminated {
            condition.unlock()
            return
        }
        if let waiting = waiter {
            waiter = nil
            condition.unlock()
            waiting.resume(returning: data)
            return
        }
        buffered.append(data)
        condition.unlock()
    }

    func finish(_ result: Result<Void, Error>) {
        condition.lock()
        guard completion == nil, !terminated else {
            condition.unlock()
            return
        }
        completion = result
        let waiting = waiter
        waiter = nil
        condition.broadcast()
        condition.unlock()
        guard let waiting else { return }
        switch result {
        case .success: waiting.resume(returning: nil)
        case .failure(let error): waiting.resume(throwing: error)
        }
    }

    /// Nil once the body has ended. Single-consumer only.
    func next() async throws -> Data? {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                condition.lock()
                if !buffered.isEmpty {
                    let chunk = buffered.removeFirst()
                    condition.broadcast()
                    condition.unlock()
                    continuation.resume(returning: chunk)
                    return
                }
                if let completion {
                    condition.unlock()
                    switch completion {
                    case .success: continuation.resume(returning: nil)
                    case .failure(let error): continuation.resume(throwing: error)
                    }
                    return
                }
                if terminated {
                    condition.unlock()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                assert(waiter == nil, "BodyChannel serves one consumer at a time")
                waiter = continuation
                condition.unlock()
            }
        } onCancel: {
            terminate()
        }
    }

    /// Releases a sender blocked on a full buffer: a consumer that walked away is not coming back.
    func terminate() {
        condition.lock()
        guard !terminated else {
            condition.unlock()
            return
        }
        terminated = true
        buffered.removeAll()
        let waiting = waiter
        waiter = nil
        let cancel = onTerminate
        condition.broadcast()
        condition.unlock()
        waiting?.resume(throwing: CancellationError())
        cancel?()
    }
}
