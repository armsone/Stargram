import Foundation
import Combine

/// Deliberately accepts no free-form payload, error, URL, or media identifier.
@MainActor
final class AIBIDiagnosticsStore: ObservableObject {
    static let shared = AIBIDiagnosticsStore()
    static let adapterVersion = "aibi-stargram-0.5.0"

    @Published private(set) var currentRunID: UUID?
    @Published private(set) var exportURL: URL?
    @Published private(set) var storageError: String?

    private struct Event: Codable {
        let stage: String
        let elapsedMilliseconds: Int
        let metrics: [String: Int]
    }

    private struct Run: Codable {
        let schemaVersion: Int
        let adapterVersion: String
        let runID: UUID
        let appVersion: String
        let appBuild: String
        let osVersion: String
        let provider: String
        var events: [Event]
        var codeDescriptions: [String: [String: String]]?
    }

    // Authored here only; persisted explanations are always replaced with these constants.
    private static let codeDescriptions: [String: [String: String]] = [
        "request_kind": ["1": "file", "2": "conversation"],
        "request_id": ["1...1000": "Page-local sequential request number starting at 1; not an account or file identifier"],
        "request_has_messages": ["0": "No messages array observed in request JSON", "1": "A messages array exists in request JSON; its content is not recorded"],
        "failure_kind": ["1": "AbortError", "2": "TypeError", "3": "other"],
        "http_status": ["0": "No HTTP response status available", "1...599": "Observed HTTP response status"],
        "image_count": ["0...100": "Observed image count"],
        "stages": [
            "request_started": "A matching request started; server acceptance is not yet confirmed",
            "request_response": "A matching request returned an HTTP status; attachment usability is not yet confirmed",
            "request_failed": "A matching request failed before a normal response"
        ]
    ]

    private static let providers: Set<String> = ["chatgpt", "gemini", "claude", "grok", "kimi", "perplexity", "unknown"]
    private static let stages: Set<String> = [
        "run_started", "media_preparation_started", "media_prepared", "media_preparation_failed",
        "browser_loaded", "browser_load_failed", "bridge_ready", "bridge_failed",
        "composer_found", "composer_missing", "attachment_started", "attachment_input_found",
        "attachment_input_missing", "attachment_dispatched", "attachment_progress", "attachment_ready",
        "attachment_failed", "attachment_timeout", "prompt_inserted", "prompt_failed",
        "send_ready", "send_attempted", "send_blocked", "send_observed", "send_timeout",
        "generation_started", "generation_progress", "generation_completed", "generation_failed",
        "response_rejected", "result_applied", "manual_takeover", "run_cancelled", "run_failed",
        "run_completed", "bridge_snapshot", "event_limit_reached",
        "request_started", "request_response", "request_failed"
    ]
    private static let metricLimits: [String: ClosedRange<Int>] = [
        "expected_count": 0...100, "prepared_count": 0...100, "attached_count": 0...100,
        "preview_count": 0...100, "input_count": 0...100, "uploading_count": 0...100,
        "failed_count": 0...100, "message_count": 0...100_000, "response_length": 0...10_000_000,
        "prompt_length": 0...10_000_000, "total_bytes": 0...1_000_000_000,
        "attempt": 0...1000, "stable_samples": 0...1000,
        "composer_present": 0...1, "send_present": 0...1, "send_enabled": 0...1,
        "stop_present": 0...1, "prompt_present": 0...1, "upload_complete": 0...1,
        "user_message_present": 0...1, "assistant_message_present": 0...1,
        "attachment_verified": 0...1, "generation_active": 0...1,
        "request_kind": 1...2, "http_status": 0...599, "failure_kind": 1...3,
        "request_id": 1...1000, "request_has_messages": 0...1,
        "image_count": 0...100
    ]

    private var runs: [UUID: Run] = [:]
    private var starts: [UUID: TimeInterval] = [:]
    private let fileManager = FileManager.default

    private init() {
        do {
            let files = try logFiles()
            try prune(files)
            // Decode and re-encode before export, so unknown JSON fields never leave the app.
            if let latest = files.first {
                let data = try Data(contentsOf: latest)
                var run = try JSONDecoder().decode(Run.self, from: data)
                guard run.schemaVersion == 1,
                      Self.providers.contains(run.provider),
                      run.adapterVersion.range(of: "^(stargram-aibi-[0-9.-]{1,30}|aibi-stargram-[0-9.]{1,20})$", options: .regularExpression) != nil,
                      Self.isVersion(run.appVersion), Self.isVersion(run.appBuild), Self.isVersion(run.osVersion) else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                run.events = Array(run.events.prefix(400)).filter { Self.stages.contains($0.stage) }.map {
                    Event(stage: $0.stage, elapsedMilliseconds: max(0, min($0.elapsedMilliseconds, 86_400_000)), metrics: Self.allowedMetrics($0.metrics))
                }
                try persist(run)
            }
        } catch {
            storageError = "진단 로그를 읽지 못했어요. AI를 다시 실행하면 새 로그를 저장합니다."
        }
    }

    @discardableResult
    func start(provider: String) -> UUID {
        let id = UUID()
        let normalized = provider.lowercased() == "openai" ? "chatgpt" : provider.lowercased()
        let run = Run(schemaVersion: 1, adapterVersion: Self.adapterVersion, runID: id,
                      appVersion: Self.version("CFBundleShortVersionString"), appBuild: Self.version("CFBundleVersion"),
                      osVersion: Self.osVersion, provider: Self.providers.contains(normalized) ? normalized : "unknown", events: [])
        runs = [id: run]
        starts = [id: ProcessInfo.processInfo.systemUptime]
        currentRunID = id
        exportURL = nil
        record(runID: id, event: "run_started")
        return id
    }

    func record(runID: UUID, event: String, metrics: [String: Int] = [:]) {
        guard Self.stages.contains(event), var run = runs[runID], let started = starts[runID], run.events.count < 400 else { return }
        let elapsed = Int(min(86_400, max(0, ProcessInfo.processInfo.systemUptime - started)) * 1000)
        let capped = run.events.count == 399
        run.events.append(Event(stage: capped ? "event_limit_reached" : event,
                                elapsedMilliseconds: elapsed, metrics: capped ? [:] : Self.allowedMetrics(metrics)))
        runs[runID] = run
        do {
            try persist(run)
            try prune(logFiles())
            storageError = nil
        } catch {
            exportURL = nil
            storageError = "진단 로그를 저장하지 못했어요. 기기 저장 공간을 확인한 뒤 AI를 다시 실행해 주세요."
        }
    }

    private static func allowedMetrics(_ metrics: [String: Int]) -> [String: Int] {
        metrics.filter { key, value in metricLimits[key]?.contains(value) == true }
    }

    private static func version(_ key: String) -> String {
        let value = Bundle.main.object(forInfoDictionaryKey: key) as? String ?? "0"
        // Version metadata only; never accept arbitrary strings as diagnostic fields.
        return isVersion(value) ? value : "0"
    }

    private static func isVersion(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 40 && value.allSatisfy { $0.isASCII && ($0.isNumber || $0 == ".") }
    }

    private static var osVersion: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }

    private func directory() throws -> URL {
        var url = try fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("AIBIDiagnostics", isDirectory: true)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
        return url
    }

    private func logFiles() throws -> [URL] {
        try fileManager.contentsOfDirectory(at: directory(), includingPropertiesForKeys: [.contentModificationDateKey])
            .filter { $0.pathExtension == "json" && UUID(uuidString: $0.deletingPathExtension().lastPathComponent) != nil }
            .sorted {
                let left = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let right = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return left > right
            }
    }

    private func prune(_ files: [URL]) throws {
        for file in files.dropFirst(10) { try fileManager.removeItem(at: file) }
    }

    private func persist(_ run: Run) throws {
        let directory = try directory()
        var destination = directory.appendingPathComponent("\(run.runID.uuidString).json")
        let temporary = directory.appendingPathComponent("\(UUID().uuidString).tmp")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var export = run
        export.codeDescriptions = Self.codeDescriptions
        let data = try encoder.encode(export)
        guard fileManager.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        defer { try? fileManager.removeItem(at: temporary) }
        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: temporary)
        } else {
            try fileManager.moveItem(at: temporary, to: destination)
        }
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try destination.setResourceValues(values)
        exportURL = destination
    }
}
