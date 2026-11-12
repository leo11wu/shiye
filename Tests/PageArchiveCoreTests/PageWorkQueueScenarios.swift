import Foundation
import PageArchiveCore

private struct QueueObservation {
    var started: [Int]
    var peak: Int
    var commitOrder: [Int]
    var peakCommits: Int
    var values: [Int: Int]
    var failures: [Int: PageWorkFailureKind]
}

/// Explicit gates make scheduling assertions independent of CPU speed or timer precision.
private actor QueueTestGate {
    private var started: [Int] = []
    private var active = Set<Int>()
    private var peak = 0
    private var workWaiters: [Int: CheckedContinuation<Void, Never>] = [:]
    private var released = Set<Int>()
    private var releaseEveryJob = false
    private var startWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var commitOrder: [Int] = []
    private var activeCommits = 0
    private var peakCommits = 0
    private var heldCommits: Set<Int>
    private var commitWaiters: [Int: CheckedContinuation<Void, Never>] = [:]
    private var commitStartWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var values: [Int: Int] = [:]
    private var failures: [Int: PageWorkFailureKind] = [:]

    init(heldCommits: Set<Int> = []) { self.heldCommits = heldCommits }

    func perform(_ index: Int) async -> Int {
        started.append(index)
        active.insert(index)
        peak = max(peak, active.count)
        let ready = startWaiters.filter { started.count >= $0.0 }
        startWaiters.removeAll { started.count >= $0.0 }
        ready.forEach { $0.1.resume() }
        await withCheckedContinuation { registerWork($0, index: index) }
        active.remove(index)
        return index * 10
    }

    private func registerWork(_ continuation: CheckedContinuation<Void, Never>, index: Int) {
        if releaseEveryJob || released.contains(index) { continuation.resume() }
        else { workWaiters[index] = continuation }
    }

    func waitForStarted(_ count: Int) async {
        guard started.count < count else { return }
        await withCheckedContinuation { startWaiters.append((count, $0)) }
    }

    func release(_ index: Int) {
        released.insert(index)
        workWaiters.removeValue(forKey: index)?.resume()
    }

    func releaseAll() {
        releaseEveryJob = true
        let waiters = Array(workWaiters.values)
        workWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func recordAttempt(_ index: Int) {
        commitOrder.append(index)
        let ready = commitStartWaiters.filter { commitOrder.count >= $0.0 }
        commitStartWaiters.removeAll { commitOrder.count >= $0.0 }
        ready.forEach { $0.1.resume() }
    }

    func commit(_ index: Int, _ result: Result<Int, PageWorkFailure>) async {
        recordAttempt(index)
        activeCommits += 1
        peakCommits = max(peakCommits, activeCommits)
        if heldCommits.contains(index) {
            await withCheckedContinuation { registerCommit($0, index: index) }
        }
        switch result {
        case let .success(value): values[index] = value
        case let .failure(failure): failures[index] = failure.kind
        }
        activeCommits -= 1
    }

    private func registerCommit(_ continuation: CheckedContinuation<Void, Never>, index: Int) {
        commitWaiters[index] = continuation
    }

    func waitForCommitStarted(_ count: Int) async {
        guard commitOrder.count < count else { return }
        await withCheckedContinuation { commitStartWaiters.append((count, $0)) }
    }

    func releaseCommit(_ index: Int) {
        heldCommits.remove(index)
        commitWaiters.removeValue(forKey: index)?.resume()
    }

    func observation() -> QueueObservation {
        QueueObservation(started: started, peak: peak, commitOrder: commitOrder,
                         peakCommits: peakCommits, values: values, failures: failures)
    }
}

func runPageWorkQueueScenarios(root: URL) throws -> [(String, Bool, String)] {
    var results: [(String, Bool, String)] = []
    func check(_ name: String, _ body: () throws -> Void) {
        do { try body(); results.append((name, true, "")); print("PASS \(name)") }
        catch { results.append((name, false, String(describing: error))); print("FAIL \(name): \(error)") }
    }

    check("批处理确实并行且默认最多同时处理两页") {
        try awaitResult {
            let gate = QueueTestGate()
            let task = Task {
                await PageWorkQueue.run(indices: Array(0..<10), operation: { await gate.perform($0) },
                                        commit: { await gate.commit($0, $1) })
            }
            await gate.waitForStarted(2)
            let initial = await gate.observation()
            await gate.releaseAll()
            let summary = await task.value
            let final = await gate.observation()
            try require(initial.started.count == 2 && initial.peak == 2)
            try require(final.peak == 2 && final.values.count == 10)
            try require(summary.progress.succeeded == 10 && summary.progress.failed == 0)
            try require(summary.progress.activeIndices.isEmpty && summary.progress.pending == 0)
        }
    }

    check("批处理按页提交乱序结果并在保存完成前停止补页") {
        try awaitResult {
            let gate = QueueTestGate(heldCommits: [2])
            let task = Task {
                await PageWorkQueue.run(indices: [7, 2, 10], operation: { await gate.perform($0) },
                                        commit: { await gate.commit($0, $1) })
            }
            await gate.waitForStarted(2)
            await gate.release(2)
            await gate.waitForCommitStarted(1)
            await gate.release(7)
            let duringSave = await gate.observation()
            await gate.releaseCommit(2)
            await gate.releaseAll()
            let summary = await task.value
            let final = await gate.observation()
            try require(duringSave.started.count == 2 && duringSave.commitOrder == [2])
            try require(final.commitOrder.first == 2 && final.peakCommits == 1)
            try require(final.values == [7: 70, 2: 20, 10: 100])
            try require(summary.progress.succeeded == 3)
        }
    }

    check("批处理取消后不启动后续页且取消不算页面失败") {
        try awaitResult {
            let gate = QueueTestGate()
            let task = Task {
                await PageWorkQueue.run(indices: Array(0..<8), operation: { await gate.perform($0) },
                                        commit: { await gate.commit($0, $1) })
            }
            await gate.waitForStarted(2)
            task.cancel()
            await gate.releaseAll()
            let summary = await task.value
            let final = await gate.observation()
            try require(final.started.count == 2 && final.commitOrder.isEmpty)
            try require(summary.cancelled && summary.progress.completed == 0)
            try require(summary.progress.failed == 0 && summary.stoppedBy == nil)
        }
    }

    check("单页识别失败不阻止其他页并保留正确页号") {
        try awaitResult {
            let gate = QueueTestGate()
            let task = Task {
                await PageWorkQueue.run(indices: Array(0..<5), operation: { index in
                    let value = await gate.perform(index)
                    if index == 2 { throw ArchiveError.message("本页结构无法解析") }
                    return value
                }, commit: { await gate.commit($0, $1) })
            }
            await gate.waitForStarted(2)
            await gate.releaseAll()
            let summary = await task.value
            let final = await gate.observation()
            try require(summary.progress.succeeded == 4 && summary.progress.failed == 1)
            try require(final.failures == [2: .page] && final.values[2] == nil)
            try require(summary.stoppedBy == nil && !summary.cancelled)
        }
    }

    check("服务错误停止队列且不启动后续付费请求") {
        try awaitResult {
            let gate = QueueTestGate()
            let task = Task {
                await PageWorkQueue.run(indices: Array(0..<8), operation: { index in
                    let value = await gate.perform(index)
                    if index == 0 { throw ProviderRequestError(statusCode: 401, message: "HTTP 401：鉴权失败。") }
                    return value
                }, commit: { await gate.commit($0, $1) })
            }
            await gate.waitForStarted(2)
            await gate.release(0)
            await gate.waitForCommitStarted(1)
            await gate.releaseAll()
            let summary = await task.value
            let final = await gate.observation()
            try require(final.started.count == 2 && final.commitOrder == [0])
            try require(summary.stoppedBy?.kind == .provider && summary.progress.failed == 1)
            try require(summary.progress.succeeded == 0 && !summary.cancelled)
        }
    }

    check("保存失败立即停止且未保存的识别结果不计为成功") {
        try awaitResult {
            let gate = QueueTestGate()
            let task = Task {
                await PageWorkQueue.run(indices: Array(0..<8), operation: { await gate.perform($0) },
                                        commit: { index, _ in
                    await gate.recordAttempt(index)
                    throw ArchiveError.message("模拟磁盘无法写入")
                })
            }
            await gate.waitForStarted(2)
            await gate.release(0)
            await gate.waitForCommitStarted(1)
            await gate.releaseAll()
            let summary = await task.value
            let final = await gate.observation()
            try require(final.started.count == 2 && final.commitOrder == [0])
            try require(summary.stoppedBy?.kind == .persistence)
            try require(summary.progress.succeeded == 0 && summary.progress.failed == 0)
            try require(final.values.isEmpty && final.failures.isEmpty)
        }
    }

    check("并发设置限制在一至四页并去重重复页号") {
        try awaitResult {
            for (requested, expected) in [(0, 1), (99, 4)] {
                let gate = QueueTestGate()
                let task = Task {
                    await PageWorkQueue.run(indices: [0, 0, 1, 2, 3, 4, 5], maxConcurrent: requested,
                                            operation: { await gate.perform($0) },
                                            commit: { await gate.commit($0, $1) })
                }
                await gate.waitForStarted(expected)
                let initial = await gate.observation()
                await gate.releaseAll()
                let summary = await task.value
                let final = await gate.observation()
                try require(initial.started.count == expected && final.peak == expected)
                try require(summary.progress.total == 6 && summary.progress.succeeded == 6)
                try require(final.started.filter { $0 == 0 }.count == 1)
            }
        }
    }

    check("服务错误保留HTTP状态供队列分类并保持既有提示") {
        var config = ProviderConfiguration()
        config.baseURL = "https://example.invalid/v1"
        let transport = StubTransport([(401, Data(), [:])])
        let backend = CompatibleVisionBackend(config: config, key: "", transport: transport)
        do {
            _ = try awaitResult { try await backend.models() }
            throw CheckFailure(description: "应返回鉴权错误")
        } catch let error as ProviderRequestError {
            try require(error.statusCode == 401)
            try require(error.localizedDescription == "HTTP 401：鉴权失败，请检查密钥和服务权限。")
            try require(PageWorkFailure.classify(error).kind == .provider)
        }
    }
    return results
}
