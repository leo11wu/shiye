import Foundation

public enum PageWorkFailureKind: String, Sendable {
    case page, provider, persistence, cancelled
}

public struct PageWorkFailure: Error, LocalizedError, Sendable {
    public var kind: PageWorkFailureKind
    public var message: String
    public var auditData: Data?
    public var errorDescription: String? { message }
    public var stopsBatch: Bool { kind == .provider || kind == .persistence }

    public init(kind: PageWorkFailureKind, message: String, auditData: Data? = nil) {
        self.kind = kind
        self.message = message
        self.auditData = auditData
    }

    public static func classify(_ error: Error) -> PageWorkFailure {
        if let failure = error as? PageWorkFailure { return failure }
        if error is CancellationError || (error as? URLError)?.code == .cancelled {
            return PageWorkFailure(kind: .cancelled, message: "已取消处理。")
        }
        if let failure=error as? OCRAgentFailure {
            return PageWorkFailure(kind:failure.providerFailure ? .provider : .page,message:failure.message,auditData:failure.auditData)
        }
        if error is ProviderRequestError {
            return PageWorkFailure(kind: .provider, message: error.localizedDescription)
        }
        return PageWorkFailure(kind: .page, message: error.localizedDescription)
    }
}

public struct PageWorkProgress: Sendable {
    public internal(set) var total: Int = 0
    public internal(set) var started: Int = 0
    public internal(set) var succeeded: Int = 0
    public internal(set) var failed: Int = 0
    public internal(set) var activeIndices: [Int] = []
    public var completed: Int { succeeded + failed }
    public var pending: Int { total - started }
}

public struct PageWorkSummary: Sendable {
    public let progress: PageWorkProgress
    public let cancelled: Bool
    public let stoppedBy: PageWorkFailure?
}

private struct PageWorkCompletion<Value> {
    let index: Int
    let result: Result<Value, PageWorkFailure>
}

/// A provider can fail while a different result is being saved. Close admission
/// immediately in that worker, rather than starting another request after the save.
private final class PageWorkAdmission: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false

    func stop() {
        lock.lock()
        stopped = true
        lock.unlock()
    }

    func admit(_ body: () -> Void) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !stopped else { return false }
        body()
        return true
    }
}

/// Runs a bounded number of independent page operations. Only `operation` is concurrent.
/// `commit` is awaited once per result, in completion order, before another page is admitted.
/// Callers own persistence and actor isolation; a UI should commit on its main actor.
public enum PageWorkQueue {
    public static func run<Value>(
        indices: [Int],
        maxConcurrent: Int = 2,
        cancelled: @escaping @Sendable () -> Bool = { false },
        operation: @escaping @Sendable (Int) async throws -> Value,
        classify: @escaping @Sendable (Error) -> PageWorkFailure = { PageWorkFailure.classify($0) },
        commit: @escaping (Int, Result<Value, PageWorkFailure>) async throws -> Void,
        progress: @escaping (PageWorkProgress) async -> Void = { _ in }
    ) async -> PageWorkSummary {
        var seen = Set<Int>()
        let jobs = indices.filter { seen.insert($0).inserted }
        let limit = min(4, max(1, maxConcurrent))
        var state = PageWorkProgress()
        state.total = jobs.count
        var wasCancelled = false
        var stoppedBy: PageWorkFailure?
        var next = 0
        let admission = PageWorkAdmission()

        await withTaskGroup(of: PageWorkCompletion<Value>.self) { group in
            func shouldCancel() -> Bool { Task.isCancelled || cancelled() }
            func addNext() -> Bool {
                guard next < jobs.count, !shouldCancel() else { return false }
                return admission.admit {
                    let index = jobs[next]
                    next += 1
                    state.started += 1
                    state.activeIndices.append(index)
                    group.addTask(priority: .userInitiated) {
                        do {
                            try Task.checkCancellation()
                            if cancelled() { throw CancellationError() }
                            let value = try await operation(index)
                            try Task.checkCancellation()
                            if cancelled() { throw CancellationError() }
                            return PageWorkCompletion(index: index, result: .success(value))
                        } catch {
                            let failure = Task.isCancelled || cancelled()
                                ? PageWorkFailure(kind: .cancelled, message: "已取消处理。")
                                : classify(error)
                            if failure.stopsBatch { admission.stop() }
                            return PageWorkCompletion(index: index, result: .failure(failure))
                        }
                    }
                }
            }

            for _ in 0..<limit { if !addNext() { break } }
            await progress(state)

            while let completion = await group.next() {
                state.activeIndices.removeAll { $0 == completion.index }
                if shouldCancel() {
                    wasCancelled = true
                    group.cancelAll()
                    break
                }
                if case let .failure(failure) = completion.result, failure.kind == .cancelled {
                    wasCancelled = true
                    group.cancelAll()
                    break
                }

                do {
                    // Saving is part of completing a page. Never count an unsaved result.
                    try await commit(completion.index, completion.result)
                } catch {
                    if error is CancellationError { wasCancelled = true }
                    else { stoppedBy = PageWorkFailure(kind: .persistence, message: error.localizedDescription) }
                    group.cancelAll()
                    break
                }
                switch completion.result {
                case .success:
                    state.succeeded += 1
                case let .failure(failure):
                    state.failed += 1
                    if failure.stopsBatch { stoppedBy = failure }
                }
                if stoppedBy != nil {
                    group.cancelAll()
                    break
                }
                if shouldCancel() {
                    wasCancelled = true
                    group.cancelAll()
                    break
                }
                _ = addNext()
                await progress(state)
            }
            if shouldCancel() { wasCancelled = true }
            // A synchronous OCR call may finish after cancellation. The group waits for it,
            // but no further result is committed and no replacement job is started.
        }
        state.activeIndices = []
        await progress(state)
        return PageWorkSummary(progress: state, cancelled: wasCancelled, stoppedBy: stoppedBy)
    }
}
