import CryptoKit
import Foundation
import os

private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "ProtocolWebhook")

/// Hands a finished protocol to an HTTP endpoint the moment it is saved.
///
/// Built for automation that used to watch the protocols folder: a webhook
/// carries the protocol itself, so the receiver needs neither file sync nor
/// access to this Mac. The URL is the only configuration and lives in the
/// Keychain, because webhook URLs usually embed their token (a Multica
/// autopilot webhook does). No URL stored — nothing is sent.
///
/// Delivery is off the pipeline's critical path: a failure is logged and
/// surfaced as a job warning, never as a failed job, and the payload waits in
/// `ProtocolWebhookOutbox` for a later attempt. Retries share
/// one `Idempotency-Key` per job, so a receiver that honours it (Multica
/// does) turns a retry or a late-naming regeneration into the same delivery
/// instead of a second one.
enum ProtocolWebhook {
    static let keychainKey = "protocolWebhookURL"

    /// Protocols run to tens of kilobytes; a long meeting with the full
    /// transcript appended can pass half a megabyte. Receivers cap request
    /// bodies, so past this size the transcript goes first, then the tail.
    /// Multica caps the whole body at 256 KiB and answers 413, which is not
    /// retried; the margin covers JSON escaping (a newline or a quote takes
    /// two bytes) and the other fields.
    static let maxMarkdownBytes = 200 * 1024
    static let maxBodyBytes = 256 * 1024
    /// The same margin for the transcript event, whose whole payload is the
    /// transcript: Multica caps the body at 256 KiB and answers 413.
    static let maxTranscriptBytes = 200 * 1024

    static let fullTranscriptMarker = "\n\n---\n\n## Full Transcript\n\n"

    struct Payload: Codable, Equatable {
        var event = "protocol.ready"
        var version = 1
        let jobID: String
        let title: String
        let app: String
        let meetingStart: String?
        let participants: [String]
        /// Calendar attendees' addresses. Left out when there are none, as
        /// payloads sent before the field existed leave it out, so a receiver
        /// has one case to handle. Added within version 1: no existing field
        /// changed.
        let participantEmails: [String]? // swiftlint:disable:this discouraged_optional_collection
        let protocolFilename: String
        let protocolMarkdown: String
        /// The markdown was cut to `maxMarkdownBytes`; the full file stays on
        /// the recording Mac.
        let truncated: Bool

        enum CodingKeys: String, CodingKey {
            case event, version, title, app, participants, truncated
            case jobID = "job_id"
            case meetingStart = "meeting_start"
            case participantEmails = "participant_emails"
            case protocolFilename = "protocol_filename"
            case protocolMarkdown = "protocol_markdown"
        }
    }

    struct JobInfo: Equatable {
        let jobID: UUID
        let title: String
        let appName: String
        let meetingStartTime: Date?
        let participants: [String]
        var participantEmails: [String] = []
    }

    static func configuredURL(read: (String) -> String? = KeychainHelper.read(key:)) -> URL? {
        guard let raw = read(keychainKey)?.trimmingCharacters(in: .whitespacesAndNewlines),
              let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              url.host != nil
        else { return nil }
        return url
    }

    /// ISO 8601 with the local offset, or nil for a meeting whose start the
    /// app never learned. Shared by both events so a receiver parses one shape.
    static func isoString(_ date: Date?) -> String? {
        date.map { ISO8601DateFormatter.string(from: $0, timeZone: .current, formatOptions: [.withInternetDateTime]) }
    }

    static func makePayload(job: JobInfo, markdown: String, protocolFilename: String) -> Payload {
        let (body, truncated) = fit(markdown, limit: maxMarkdownBytes)
        let start = isoString(job.meetingStartTime)
        return Payload(
            jobID: job.jobID.uuidString,
            title: job.title,
            app: job.appName,
            meetingStart: start,
            participants: job.participants,
            participantEmails: job.participantEmails.isEmpty ? nil : job.participantEmails,
            protocolFilename: protocolFilename,
            protocolMarkdown: body,
            truncated: truncated,
        )
    }

    /// Drop the appended full transcript first, then cut on a character
    /// boundary. Returns the text and whether anything was removed.
    static func fit(_ markdown: String, limit: Int) -> (String, Bool) {
        if markdown.utf8.count <= limit { return (markdown, false) }
        var text = markdown
        if let range = text.range(of: fullTranscriptMarker) {
            text = String(text[..<range.lowerBound])
        }
        if text.utf8.count > limit {
            var cut = ""
            var bytes = 0
            for char in text {
                let size = String(char).utf8.count
                if bytes + size > limit { break }
                cut.append(char)
                bytes += size
            }
            text = cut
        }
        return (text, true)
    }

    static func makeRequest(url: URL, body: Body) throws -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(body.idempotencyKey, forHTTPHeaderField: "Idempotency-Key")
        request.setValue("MeetingTranscriber/\(Bundle.main.appVersion)", forHTTPHeaderField: "User-Agent")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        request.httpBody = try encoder.encode(body)
        return request
    }

    /// Convenience for the protocol event, the body that existed first.
    static func makeRequest(url: URL, payload: Payload) throws -> URLRequest {
        try makeRequest(url: url, body: .protocolReady(payload))
    }

    enum Outcome: Equatable {
        case delivered(status: Int)
        /// 4xx other than 408/429: the endpoint rejected the request and a
        /// retry would be rejected the same way.
        case rejected(status: Int)
        case failed(String)
    }

    /// Send with retries on transport errors, 408, 429 and 5xx.
    static func send(
        _ request: URLRequest,
        session: URLSession = .shared,
        retryDelays: [Duration] = [.seconds(5), .seconds(30), .seconds(120)],
        sleep: (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
    ) async -> Outcome {
        var lastFailure = ""
        for attempt in 0 ... retryDelays.count {
            if attempt > 0 {
                do { try await sleep(retryDelays[attempt - 1]) } catch { return .failed("cancelled") }
            }
            do {
                let (_, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    lastFailure = "non-HTTP response"
                    continue
                }
                switch http.statusCode {
                case 200 ..< 300:
                    return .delivered(status: http.statusCode)

                case 408, 429, 500...:
                    lastFailure = "HTTP \(http.statusCode)"

                default:
                    return .rejected(status: http.statusCode)
                }
            } catch {
                lastFailure = (error as? URLError).map { "URLError \($0.code.rawValue)" } ?? "transport error"
            }
        }
        return .failed(lastFailure)
    }

    static let defaultRetryDelays: [Duration] = [.seconds(5), .seconds(30), .seconds(120)]

    /// Send one payload and settle its place in the outbox: queued when it
    /// could not be delivered, removed when it was delivered or rejected. A
    /// delivery proves the receiver is reachable again, so whatever waited in
    /// the outbox goes next; what that flush gave up on goes to `notify`.
    static func deliver(
        _ body: Body,
        to url: URL,
        outbox: ProtocolWebhookOutbox,
        session: URLSession = .shared,
        retryDelays: [Duration] = defaultRetryDelays,
        sleep: (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        notify: @Sendable (String) -> Void = { _ in },
    ) async -> Outcome {
        let outcome: Outcome
        do {
            outcome = try await send(
                makeRequest(url: url, body: body), session: session, retryDelays: retryDelays, sleep: sleep,
            )
        } catch {
            // Encoding a plain struct of strings does not fail in practice;
            // if it ever did, a retry would fail the same way.
            outcome = .rejected(status: 0)
        }
        switch outcome {
        case .delivered:
            await outbox.remove(jobID: body.jobID)
            let report = await outbox.flush(url: url, session: session)
            if let message = ProtocolWebhookOutbox.notice(for: report) { notify(message) }

        case .rejected:
            await outbox.remove(jobID: body.jobID)

        case .failed:
            await outbox.save(body)
        }
        return outcome
    }

    /// Convenience for the protocol event; see `deliver(_:to:outbox:...)`.
    static func deliver(
        _ payload: Payload,
        to url: URL,
        outbox: ProtocolWebhookOutbox,
        session: URLSession = .shared,
        retryDelays: [Duration] = defaultRetryDelays,
        sleep: (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        notify: @Sendable (String) -> Void = { _ in },
    ) async -> Outcome {
        await deliver(
            .protocolReady(payload), to: url, outbox: outbox, session: session,
            retryDelays: retryDelays, sleep: sleep, notify: notify,
        )
    }

    /// Fire-and-forget entry point for the pipeline. `warn` runs on the main
    /// actor with a content-free message when delivery did not succeed.
    static func deliverIfConfigured(
        job: JobInfo,
        protocolPath: URL,
        warn: @escaping @MainActor (String) -> Void,
    ) {
        guard let url = configuredURL() else { return }
        let shortID = PipelineJob.shortID(for: job.jobID)
        Task.detached(priority: .utility) {
            let outcome: Outcome
            do {
                let markdown = try String(contentsOf: protocolPath, encoding: .utf8)
                let payload = makePayload(
                    job: job, markdown: markdown, protocolFilename: protocolPath.lastPathComponent,
                )
                outcome = await deliver(payload, to: url, outbox: .shared, notify: notifyUser)
            } catch {
                outcome = .failed("could not read protocol")
            }
            switch outcome {
            case let .delivered(status):
                logger.info("[\(shortID, privacy: .public)] protocol_webhook_delivered status=\(status, privacy: .public)")

            case let .rejected(status):
                logger.error("[\(shortID, privacy: .public)] protocol_webhook_rejected status=\(status, privacy: .public)")
                await warn("Protocol webhook rejected (HTTP \(status))")

            case let .failed(reason):
                logger.error("[\(shortID, privacy: .public)] protocol_webhook_failed reason=\(reason, privacy: .public)")
                await warn("Protocol webhook not delivered yet; queued for retry")
            }
        }
    }

    /// Where outbox notices go: they concern protocols whose jobs may be long
    /// gone, so a notification rather than a job warning.
    static let notifyUser: @Sendable (String) -> Void = { message in
        NotificationManager.shared.notify(title: "Protocol webhook", body: message)
    }
}

extension ProtocolWebhook {
    /// Short fingerprint for logs and the settings row; never the URL itself,
    /// which carries the token.
    static func fingerprint(of url: URL) -> String {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        return (url.host ?? "?") + " · " + digest.prefix(3).map { String(format: "%02x", $0) }.joined()
    }
}
