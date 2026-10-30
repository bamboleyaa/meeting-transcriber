import Foundation
import os

private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "ProtocolWebhookOutbox")

/// Payloads the webhook could not deliver, kept on disk until it can.
///
/// Without it a protocol whose delivery failed (offline laptop, receiver
/// down past the in-process retries) never reached the receiver at all: the
/// warning on the job was the only trace. One file per job,
/// `webhook-outbox/<job_id>.json`, owner-only because it holds the protocol
/// text. The URL is not stored: it carries a token and lives in the Keychain,
/// so a retry reads the current one.
///
/// Retried at launch, periodically, and after any successful delivery (the
/// receiver is evidently reachable again), with the job id as the
/// `Idempotency-Key` again, so a payload that did arrive after all is not
/// processed twice. A 2xx or a rejecting 4xx removes the file; so does age:
/// after `maxAge` the entry is dropped with a notice rather than retried
/// forever. The protocol itself stays in the protocols folder either way.
actor ProtocolWebhookOutbox {
    struct Entry: Codable, Equatable {
        let createdAt: Date
        /// A protocol or a transcript event; `Body` decodes both, including
        /// entries written before the transcript event existed.
        let payload: ProtocolWebhook.Body

        enum CodingKeys: String, CodingKey {
            case payload
            case createdAt = "created_at"
        }
    }

    struct FlushReport: Equatable {
        var delivered: [String] = []
        var rejected: [String] = []
        var expired: [String] = []
        /// Entries left for the next attempt.
        var remaining = 0
    }

    static let defaultMaxAge: TimeInterval = 7 * 24 * 3600

    static let shared = ProtocolWebhookOutbox(
        directory: AppPaths.dataDir.appendingPathComponent("webhook-outbox", isDirectory: true),
    )

    let directory: URL
    private let maxAge: TimeInterval
    private let now: @Sendable () -> Date
    private var isFlushing = false

    init(directory: URL, maxAge: TimeInterval = defaultMaxAge, now: @escaping @Sendable () -> Date = { Date() }) {
        self.directory = directory
        self.maxAge = maxAge
        self.now = now
    }

    private func fileURL(jobID: String) -> URL {
        directory.appendingPathComponent(jobID).appendingPathExtension("json")
    }

    /// Queue a payload. A job already queued keeps its original date, so a
    /// regeneration that fails too does not extend its life.
    func save(_ body: ProtocolWebhook.Body) {
        guard UUID(uuidString: body.jobID) != nil else { return }
        let url = fileURL(jobID: body.jobID)
        let createdAt = load(url)?.createdAt ?? now()
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700],
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(Entry(createdAt: createdAt, payload: body)).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            logger.info("webhook_queued job=\(body.jobID, privacy: .public) event=\(body.idempotencyKey, privacy: .public)")
        } catch {
            logger.error("protocol_webhook_queue_failed error=\(error.localizedDescription, privacy: .public)")
        }
    }

    func remove(jobID: String) {
        try? FileManager.default.removeItem(at: fileURL(jobID: jobID))
    }

    /// Queued job ids, oldest first.
    func pending() -> [String] {
        entries().map(\.payload.jobID)
    }

    private func load(_ url: URL) -> Entry? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Entry.self, from: data)
    }

    private func entries() -> [Entry] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.pathExtension == "json" && UUID(uuidString: $0.deletingPathExtension().lastPathComponent) != nil }
            .compactMap(load)
            .sorted { $0.createdAt < $1.createdAt }
    }

    /// One attempt per queued payload, oldest first. Stops at the first
    /// failure: the receiver or the network is down, and the rest would fail
    /// the same way. A flush already running makes this one a no-op.
    func flush(url: URL, session: URLSession = .shared) async -> FlushReport {
        var report = FlushReport()
        guard !isFlushing else { return report }
        isFlushing = true
        defer { isFlushing = false }

        var queue = entries()[...]
        while let entry = queue.popFirst() {
            let jobID = entry.payload.jobID
            if now().timeIntervalSince(entry.createdAt) > maxAge {
                remove(jobID: jobID)
                report.expired.append(jobID)
                logger.error("protocol_webhook_expired job=\(jobID, privacy: .public)")
                continue
            }
            let outcome: ProtocolWebhook.Outcome
            do {
                let request = try ProtocolWebhook.makeRequest(url: url, body: entry.payload)
                outcome = await ProtocolWebhook.send(request, session: session, retryDelays: [])
            } catch {
                outcome = .rejected(status: 0)
            }
            switch outcome {
            case .delivered:
                remove(jobID: jobID)
                report.delivered.append(jobID)
                logger.info("protocol_webhook_redelivered job=\(jobID, privacy: .public)")

            case let .rejected(status):
                remove(jobID: jobID)
                report.rejected.append(jobID)
                logger.error("protocol_webhook_rejected_on_retry job=\(jobID, privacy: .public) status=\(status, privacy: .public)")

            case let .failed(reason):
                report.remaining = queue.count + 1
                logger.info("protocol_webhook_retry_failed reason=\(reason, privacy: .public)")
                return report
            }
        }
        return report
    }
}

extension ProtocolWebhookOutbox {
    /// The user-facing sentence for what a flush gave up on, nil when it gave
    /// up on nothing. Content-free, like the job warnings.
    static func notice(for report: FlushReport) -> String? {
        var parts: [String] = []
        if !report.rejected.isEmpty {
            parts.append("\(report.rejected.count) queued webhook message(s) rejected by the webhook")
        }
        if !report.expired.isEmpty {
            parts.append("\(report.expired.count) webhook message(s) not delivered within 7 days and dropped from the retry queue")
        }
        return parts.isEmpty ? nil : parts.joined(separator: "; ") + ". The meeting files stay on this Mac."
    }

    /// Retry at launch and then every `interval` for the life of the app.
    /// Started from the app scene, never from `AppState`, which unit tests
    /// construct too.
    static func startRetrying(
        interval: Duration = .seconds(15 * 60),
        initialDelay: Duration = .seconds(30),
        notify: @escaping @Sendable (String) -> Void,
    ) {
        Task.detached(priority: .utility) {
            try? await Task.sleep(for: initialDelay)
            while !Task.isCancelled {
                if let url = ProtocolWebhook.configuredURL() {
                    let report = await shared.flush(url: url)
                    if let message = notice(for: report) { notify(message) }
                }
                try? await Task.sleep(for: interval)
            }
        }
    }
}
