// Local-only OCR benchmark. Build with the current PageArchiveCore library:
// swiftc -O -parse-as-library -I <build> -L <build> -lPageArchiveCore \
//   -Xlinker -rpath -Xlinker <build> scripts/check_page_concurrency.swift -o <benchmark>
// <benchmark> prepare <source.pdf> <fresh-output-directory> [page-limit|all]
// <benchmark> run <prepared-directory> <fresh-run-directory> <1|2|4>
// Each run is a separate process, copies the unrecognized project, and saves each
// completed page serially on MainActor. No API calls are made. Source files are read only.
import Foundation
import PDFKit
import Darwin
import PageArchiveCore

private struct BenchmarkError: Error, CustomStringConvertible {
    let description: String
}

private final class ActiveOperations: @unchecked Sendable {
    private let lock = NSLock()
    private var active = 0
    private var peak = 0
    private var starts: [Int: Double] = [:]
    private var durations: [Int: Double] = [:]

    func begin(_ index: Int) {
        lock.lock(); defer { lock.unlock() }
        active += 1
        peak = max(peak, active)
        starts[index] = ProcessInfo.processInfo.systemUptime
    }

    func end(_ index: Int) {
        lock.lock(); defer { lock.unlock() }
        active -= 1
        durations[index] = ProcessInfo.processInfo.systemUptime - (starts[index] ?? 0)
    }

    func report() -> (Int, [[String: Any]]) {
        lock.lock(); defer { lock.unlock() }
        return (peak, durations.keys.sorted().map {
            ["projectPage": $0 + 1, "ocrSeconds": durations[$0] ?? 0]
        })
    }
}

@MainActor
private final class BenchmarkSink {
    let store: ProjectStore
    var document: BookDocument
    var saveSeconds: Double = 0

    init(store: ProjectStore, document: BookDocument) {
        self.store = store
        self.document = document
    }

    func commit(_ index: Int, _ result: Result<Page, PageWorkFailure>) throws {
        var next = document
        switch result {
        case let .success(page):
            next.pages[index] = page
            next.edits.append(EditRecord(pageID: page.id, action: "并发实测：本机 OCR 初稿，未核对"))
        case let .failure(error):
            next.pages[index].status = .failed
            next.pages[index].error = error.message
        }
        let started = ProcessInfo.processInfo.systemUptime
        try store.save(next)
        saveSeconds += ProcessInfo.processInfo.systemUptime - started
        document = next
    }
}

private func writeJSON(_ value: [String: Any], to url: URL) throws {
    try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
        .write(to: url, options: .atomic)
}

@main
private struct ConcurrencyBenchmark {
    @MainActor
    static func main() async {
        do {
            let args = CommandLine.arguments
            if (4...5).contains(args.count), args[1] == "prepare" {
                let requested = args.count == 5 ? args[4] : "10"
                guard requested == "all" || (Int(requested).map { $0 > 0 } ?? false) else {
                    throw BenchmarkError(description: "The page limit must be a positive integer or all.")
                }
                try prepare(source: URL(fileURLWithPath: args[2]), output: URL(fileURLWithPath: args[3]),
                            pageLimit: requested == "all" ? nil : Int(requested))
            } else if args.count == 5, args[1] == "run", let concurrency = Int(args[4]), (1...4).contains(concurrency) {
                try await run(prepared: URL(fileURLWithPath: args[2]), output: URL(fileURLWithPath: args[3]), concurrency: concurrency)
            } else {
                throw BenchmarkError(description: "Usage: benchmark prepare source.pdf output-dir [page-limit|all] | benchmark run prepared-dir run-dir concurrency")
            }
        } catch {
            fputs("Benchmark failed: \(error)\n", stderr)
            exit(1)
        }
    }

    private static func prepare(source: URL, output: URL, pageLimit: Int?) throws {
        guard !FileManager.default.fileExists(atPath: output.path) else {
            throw BenchmarkError(description: "Preparation destination already exists; use a fresh directory.")
        }
        guard let original = PDFDocument(url: source), !original.isLocked, original.pageCount > 0 else {
            throw BenchmarkError(description: "The source must be a nonempty, unlocked PDF.")
        }
        let selectedCount = pageLimit.map { min($0, original.pageCount) } ?? original.pageCount
        let beforeHash = try Digest.file(source)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let extract = output.appendingPathComponent("selected-pages.pdf")
        if selectedCount == original.pageCount {
            // Whole-document runs preserve the original PDF bytes in the temporary copy.
            try FileManager.default.copyItem(at: source, to: extract)
        } else {
            let selected = PDFDocument()
            for index in 0..<selectedCount {
                guard let page = original.page(at: index)?.copy() as? PDFPage else {
                    throw BenchmarkError(description: "Cannot copy source page \(index + 1).")
                }
                selected.insert(page, at: index)
            }
            guard selected.write(to: extract) else { throw BenchmarkError(description: "Cannot write the selected-page extraction.") }
        }
        let store = try ProjectStore(root: output.appendingPathComponent("unrecognized.shiyebook"))
        var document = BookDocument(title: "Local OCR concurrency benchmark — \(source.lastPathComponent), \(selectedCount) pages")
        try PageImporter.append(urls: [extract], to: &document, store: store)
        guard document.pages.count == selectedCount, document.pages.allSatisfy({ $0.blocks.isEmpty }) else {
            throw BenchmarkError(description: "Expected exactly \(selectedCount) unrecognized pages.")
        }
        guard try Digest.file(source) == beforeHash else {
            throw BenchmarkError(description: "Source checksum changed during preparation.")
        }
        try writeJSON([
            "sourcePath": source.path,
            "sourceSHA256": beforeHash,
            "sourcePageCount": original.pageCount,
            "selectedSourcePages": Array(1...selectedCount),
            "requestedPageLimit": pageLimit.map { String($0) } ?? "all",
            "renderVersion": PageImporter.renderVersion,
            "projectPath": store.root.path,
            "sourceUnchanged": true,
            "usesCloudAPI": false
        ], to: output.appendingPathComponent("preparation.json"))
        print("Prepared \(selectedCount) pages: \(store.root.path)")
    }

    @MainActor
    private static func run(prepared: URL, output: URL, concurrency: Int) async throws {
        guard !FileManager.default.fileExists(atPath: output.path) else {
            throw BenchmarkError(description: "Run destination already exists; use a fresh directory.")
        }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let root = output.appendingPathComponent("project.shiyebook")
        try FileManager.default.copyItem(at: prepared.appendingPathComponent("unrecognized.shiyebook"), to: root)
        let store = try ProjectStore(root: root)
        let document = try store.load()
        guard !document.pages.isEmpty, document.pages.allSatisfy({ $0.blocks.isEmpty }) else {
            throw BenchmarkError(description: "Benchmark input must contain pages without recognition results.")
        }
        let preparation = try JSONSerialization.jsonObject(with: Data(contentsOf: prepared.appendingPathComponent("preparation.json"))) as? [String: Any] ?? [:]
        let pages = document.pages
        let active = ActiveOperations()
        let sink = BenchmarkSink(store: store, document: document)
        let started = ProcessInfo.processInfo.systemUptime
        let summary = await PageWorkQueue.run(indices: Array(pages.indices), maxConcurrent: concurrency,
            operation: { index in
                active.begin(index)
                defer { active.end(index) }
                return try LocalBookOCR.recognize(page: pages[index], store: store)
            }, commit: { index, result in
                try await MainActor.run { try sink.commit(index, result) }
            })
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        let operationReport = active.report()
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { throw BenchmarkError(description: "getrusage failed.") }
        // On Darwin ru_maxrss is bytes; external /usr/bin/time -l can independently check it.
        let peakResidentBytes = Int64(usage.ru_maxrss)
        let report: [String: Any] = [
            "concurrency": concurrency,
            "pageCount": pages.count,
            "sourcePath": preparation["sourcePath"] ?? NSNull(),
            "sourceSHA256": preparation["sourceSHA256"] ?? NSNull(),
            "selectedSourcePages": preparation["selectedSourcePages"] ?? NSNull(),
            "peakActiveOperations": operationReport.0,
            "wallSeconds": elapsed,
            "serialSaveSeconds": sink.saveSeconds,
            "succeeded": summary.progress.succeeded,
            "failed": summary.progress.failed,
            "cancelled": summary.cancelled,
            "stoppedBy": summary.stoppedBy?.message ?? NSNull(),
            "peakResidentBytes": peakResidentBytes,
            "peakResidentMiB": Double(peakResidentBytes) / 1_048_576,
            "cpuUserSeconds": Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1_000_000,
            "cpuSystemSeconds": Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1_000_000,
            "operatingSystem": ProcessInfo.processInfo.operatingSystemVersionString,
            "processorCount": ProcessInfo.processInfo.processorCount,
            "physicalMemoryBytes": ProcessInfo.processInfo.physicalMemory,
            "pageTimings": operationReport.1,
            "pageResults": sink.document.pages.enumerated().map { index, page -> [String: Any] in
                let text = page.orderedBlocks.map(\.plainText).joined(separator: "\n")
                return ["projectPage": index + 1, "status": page.status.rawValue,
                        "blockCount": page.blocks.count, "characterCount": text.count,
                        "textSHA256": Digest.sha256(Data(text.utf8)), "error": page.error ?? NSNull()]
            },
            "timingScope": "Local OCR for all prepared pages plus serial per-page project saves; excludes extraction/import and project copy.",
            "memoryScope": "Peak process resident memory (Darwin getrusage); includes library loading and project copy/load, excludes other processes and separately allocated GPU memory.",
            "accuracyMeasured": false,
            "usesCloudAPI": false
        ]
        let reportURL = output.appendingPathComponent("benchmark.json")
        try writeJSON(report, to: reportURL)
        print("Concurrency \(concurrency): peak active \(operationReport.0), \(summary.progress.succeeded)/\(pages.count) succeeded, \(summary.progress.failed) failed, \(String(format: "%.2f", elapsed)) s, \(String(format: "%.1f", Double(peakResidentBytes) / 1_048_576)) MiB peak RSS")
        print("Report: \(reportURL.path)")
        if summary.progress.completed != pages.count || summary.progress.failed > 0 || summary.stoppedBy != nil {
            throw BenchmarkError(description: "Benchmark finished with incomplete or failed pages; see its report.")
        }
    }
}
