import Foundation
import Combine

/// Deliberately accepts no free-form payload, error, URL, or media identifier.
@MainActor
final class AIBIDiagnosticsStore: ObservableObject {
    static let shared = AIBIDiagnosticsStore()
    static let adapterVersion = "aibi-stargram-0.5.5"

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
        "failure_kind": ["1": "AbortError (browser_load_failed: navigation cancelled)", "2": "TypeError (request_failed error name, or bridge_failed page JavaScript exception)", "3": "other", "4": "bridge_failed: observer helper missing or unsupported result"],
        "http_status": ["0": "No HTTP response status available", "1...599": "Observed HTTP response status"],
        "image_count": ["0...100": "Observed image count"],
        "stages": [
            "request_started": "A matching request started; server acceptance is not yet confirmed",
            "request_response": "A matching request returned an HTTP status; attachment usability is not yet confirmed",
            "request_failed": "A matching request failed before a normal response",
            "navigation_started": "A main-frame navigation started; the page is not ready until it commits and becomes interactive",
            "navigation_committed": "The current main-frame navigation committed a new document",
            "bridge_ready": "The committed document reported interactive readiness before didFinish",
            "prompt_failed": "The observer was present but rejected prompt insertion",
            "bridge_failed": "The observer helper was missing or JavaScript evaluation failed",
            "send_attempted": "The single automatic send click was dispatched; Gemini also reports stable_samples, the consecutive polling turns with the same connected editor, unique enabled send, unchanged input and attachment count on a complete document before that click",
            "send_blocked": "Send was held without clicking: attachments unverified, or prompt_present 0 when the loaded composer no longer matched the inserted prompt before any send attempt (attempt = successful fills so far)",
            "auth_probe_controls": "Login sheet only, once per page: counts of visible exact sidebar-control markers before any click (labels, test ids, sidebar aria-controls, pin, close, generic menu names never clicked), hidden copies, click kind and whether an account marker was visible afterwards; attempt = sidebar clicks so far. No text, attribute value, URL or DOM"
        ],
        "sidebar_expanded": ["0": "Single candidate without aria-expanded", "1": "Single candidate aria-expanded false", "2": "Single candidate aria-expanded true", "3": "No single candidate"],
        "sidebar_click_kind": ["0": "Not clicked", "1": "Clicked a control with explicit collapsed state", "2": "Clicked a stateless exact sidebar toggle (at most once per page)"]
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
        "request_started", "request_response", "request_failed",
        "composer_reset", "navigation_started", "navigation_committed", "auth_probe_controls"
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
        "request_kind": 1...2, "http_status": 0...599, "failure_kind": 1...4,
        "request_id": 1...1000, "request_has_messages": 0...1,
        "image_count": 0...100,
        "composer_ready": 0...1, "root_present": 0...1, "reset_tiles": 0...100, "reset_clicks": 0...100, "reset_error": 0...3,
        "sidebar_open_label_count": 0...100, "sidebar_toggle_label_count": 0...100, "sidebar_close_label_count": 0...100,
        "sidebar_testid_count": 0...100, "sidebar_pin_count": 0...100, "sidebar_controls_count": 0...100,
        "sidebar_named_count": 0...100, "sidebar_hidden_count": 0...100, "sidebar_candidate_count": 0...100,
        "menu_label_count": 0...100, "sidebar_expanded": 0...3, "document_complete": 0...1,
        "sidebar_click_kind": 0...2, "auth_marker_present": 0...1
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

    /// 로그인 확인 화면의 일회성 숫자 기록. 진행 중인 AI 실행(`runs`, `currentRunID`)은 건드리지 않고
    /// 이벤트 하나짜리 별도 실행 파일로 저장한다(최근 10개 보존·내보내기 규칙은 같다).
    func recordProbeSnapshot(provider: String, event: String, elapsedMilliseconds: Int, metrics: [String: Int]) {
        guard event == "auth_probe_controls", Self.providers.contains(provider) else { return }
        let run = Run(schemaVersion: 1, adapterVersion: Self.adapterVersion, runID: UUID(),
                      appVersion: Self.version("CFBundleShortVersionString"), appBuild: Self.version("CFBundleVersion"),
                      osVersion: Self.osVersion, provider: provider,
                      events: [Event(stage: event, elapsedMilliseconds: max(0, min(elapsedMilliseconds, 86_400_000)),
                                     metrics: Self.allowedMetrics(metrics))])
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
