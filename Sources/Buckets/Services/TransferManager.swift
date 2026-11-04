import Foundation
import Observation

/// Limits how many transfers run at once.
actor AsyncLimiter {
    private var available: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) { available = limit }

    func acquire() async {
        if available > 0 {
            available -= 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty {
            available += 1
        } else {
            waiters.removeFirst().resume()
        }
    }
}

/// Coalesces high-frequency progress callbacks.
final class ProgressThrottle: @unchecked Sendable {
    private let lock = NSLock()
    private var lastEmit: CFAbsoluteTime = 0

    func shouldEmit(done: Int64, total: Int64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let now = CFAbsoluteTimeGetCurrent()
        if (total > 0 && done >= total) || now - lastEmit > 0.08 {
            lastEmit = now
            return true
        }
        return false
    }
}

@MainActor
@Observable
final class Transfer: Identifiable {
    enum Direction { case upload, download }
    enum State: Equatable { case queued, running, completed, failed(String), cancelled }
    typealias Operation = @Sendable (_ progress: @escaping @Sendable (Int64, Int64) -> Void) async throws -> Void

    let id = UUID()
    let name: String
    let isFolder: Bool
    let direction: Direction
    /// Human-readable destination ("photos/2024", "Downloads").
    let destination: String
    let localURL: URL?
    let operation: Operation
    let onFinish: ((Bool) -> Void)?

    var state: State = .queued
    var bytesDone: Int64 = 0
    var bytesTotal: Int64
    var startedAt: Date?
    var finishedAt: Date?
    @ObservationIgnored var task: Task<Void, Never>?

    init(
        name: String,
        isFolder: Bool,
        direction: Direction,
        destination: String,
        totalBytes: Int64,
        localURL: URL?,
        operation: @escaping Operation,
        onFinish: ((Bool) -> Void)?
    ) {
        self.name = name
        self.isFolder = isFolder
        self.direction = direction
        self.destination = destination
        self.bytesTotal = totalBytes
        self.localURL = localURL
        self.operation = operation
        self.onFinish = onFinish
    }

    var isActive: Bool { state == .queued || state == .running }

    var fractionCompleted: Double {
        if state == .completed { return 1 }
        guard bytesTotal > 0 else { return 0 }
        return min(1, Double(bytesDone) / Double(bytesTotal))
    }

    var bytesPerSecond: Double? {
        guard state == .running, let startedAt else { return nil }
        let elapsed = Date().timeIntervalSince(startedAt)
        guard elapsed > 1, bytesDone > 0 else { return nil }
        return Double(bytesDone) / elapsed
    }

    var secondsRemaining: Double? {
        guard let rate = bytesPerSecond, rate > 0, bytesTotal > bytesDone else { return nil }
        return Double(bytesTotal - bytesDone) / rate
    }

    func update(done: Int64, total: Int64) {
        guard state == .running else { return }
        bytesDone = done
        if total > 0 { bytesTotal = total }
    }
}

@MainActor
@Observable
final class TransferManager {
    private(set) var transfers: [Transfer] = []
    @ObservationIgnored private let limiter = AsyncLimiter(limit: 4)

    var activeTransfers: [Transfer] { transfers.filter(\.isActive) }
    var hasActive: Bool { transfers.contains(where: \.isActive) }
    var hasFinished: Bool { transfers.contains { !$0.isActive } }

    var overallProgress: Double {
        let active = activeTransfers
        guard !active.isEmpty else { return 0 }
        let total = active.reduce(Int64(0)) { $0 + max($1.bytesTotal, 1) }
        let done = active.reduce(Int64(0)) { $0 + min($1.bytesDone, max($1.bytesTotal, 1)) }
        return total > 0 ? Double(done) / Double(total) : 0
    }

    @discardableResult
    func enqueue(
        name: String,
        isFolder: Bool = false,
        direction: Transfer.Direction,
        destination: String,
        totalBytes: Int64,
        localURL: URL? = nil,
        operation: @escaping Transfer.Operation,
        onFinish: ((Bool) -> Void)? = nil
    ) -> Transfer {
        let transfer = Transfer(
            name: name,
            isFolder: isFolder,
            direction: direction,
            destination: destination,
            totalBytes: totalBytes,
            localURL: localURL,
            operation: operation,
            onFinish: onFinish
        )
        transfers.insert(transfer, at: 0)
        start(transfer)
        return transfer
    }

    func cancel(_ transfer: Transfer) {
        transfer.task?.cancel()
        if transfer.state == .queued { transfer.state = .cancelled }
    }

    func retry(_ transfer: Transfer) {
        guard !transfer.isActive else { return }
        start(transfer)
    }

    func remove(_ transfer: Transfer) {
        guard !transfer.isActive else { return }
        transfers.removeAll { $0.id == transfer.id }
    }

    func clearFinished() {
        transfers.removeAll { !$0.isActive }
    }

    private func start(_ transfer: Transfer) {
        transfer.state = .queued
        transfer.bytesDone = 0
        transfer.startedAt = nil
        transfer.finishedAt = nil
        let limiter = self.limiter

        transfer.task = Task {
            await limiter.acquire()
            if Task.isCancelled || transfer.state == .cancelled {
                transfer.state = .cancelled
                await limiter.release()
                transfer.onFinish?(false)
                return
            }

            transfer.state = .running
            transfer.startedAt = Date()
            let throttle = ProgressThrottle()

            do {
                try await transfer.operation { done, total in
                    guard throttle.shouldEmit(done: done, total: total) else { return }
                    Task { @MainActor in transfer.update(done: done, total: total) }
                }
                transfer.bytesDone = transfer.bytesTotal
                transfer.state = .completed
                transfer.finishedAt = Date()
                await limiter.release()
                transfer.onFinish?(true)
            } catch {
                transfer.state = (Task.isCancelled || isCancellation(error)) ? .cancelled : .failed(error.localizedDescription)
                transfer.finishedAt = Date()
                await limiter.release()
                transfer.onFinish?(false)
            }
        }
    }
}
