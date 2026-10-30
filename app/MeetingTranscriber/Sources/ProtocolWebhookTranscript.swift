import Foundation
import os

private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "ProtocolWebhook")

/// The `event` value that marks a transcript body, shared by the payload and
/// the `Body` discriminator.
let transcriptEventName = "transcript.ready"

/// The transcript event: when the transcript is saved and no protocol will be
/// produced, the raw transcript goes to the same webhook instead.
///
/// The protocol used to be the only thing this app could hand over, and it
/// needs an LLM on the recording Mac. A meeting recorded without one — the
/// provider is None, or the generation failed — reached the receiver not at
/// all, even though its transcript existed. This event carries that transcript
/// so the receiver can build the protocol itself.
extension ProtocolWebhook {
    struct TranscriptPayload: Codable, Equatable {
        static let eventName = transcriptEventName

        var event = transcriptEventName
        var version = 1
        let jobID: String
        let title: String
        let app: String
        let meetingStart: String?
        let participants: [String]
        /// Calendar attendees' addresses, left out when there are none, as in
        /// `Payload`.
        let participantEmails: [String]? // swiftlint:disable:this discouraged_optional_collection
        let transcriptFilename: String
        let transcript: String
        /// The transcript was cut to `maxTranscriptBytes`; the full file stays
        /// on the recording Mac.
        let truncated: Bool

        enum CodingKeys: String, CodingKey {
            case event, version, title, app, participants, truncated, transcript
            case jobID = "job_id"
            case meetingStart = "meeting_start"
            case participantEmails = "participant_emails"
            case transcriptFilename = "transcript_filename"
        }
    }

    /// One webhook request body. The outbox stores it as-is, so a retry sends
    /// the same event, and a body queued by an older build (a bare protocol
    /// payload, no discriminator) still decodes: `event` says which kind it is.
    enum Body: Codable, Equatable {
        case protocolReady(Payload)
        case transcriptReady(TranscriptPayload)

        /// The job this delivery belongs to: the outbox file name and the
        /// stem of the `Idempotency-Key`.
        var jobID: String {
            switch self {
            case let .protocolReady(payload): payload.jobID
            case let .transcriptReady(payload): payload.jobID
            }
        }

        /// One key per job and event kind: retries of one event collapse into
        /// one delivery at a receiver that honours the key, while a transcript
        /// and a later protocol for the same job stay two separate events.
        var idempotencyKey: String {
            switch self {
            case let .protocolReady(payload): payload.jobID
            case let .transcriptReady(payload): "transcript-\(payload.jobID)"
            }
        }

        private enum ProbeKeys: String, CodingKey {
            case event
        }

        init(from decoder: any Decoder) throws {
            let event = try decoder.container(keyedBy: ProbeKeys.self).decode(String.self, forKey: .event)
            if event == TranscriptPayload.eventName {
                self = try .transcriptReady(TranscriptPayload(from: decoder))
            } else {
                self = try .protocolReady(Payload(from: decoder))
            }
        }

        func encode(to encoder: any Encoder) throws {
            switch self {
            case let .protocolReady(payload): try payload.encode(to: encoder)
            case let .transcriptReady(payload): try payload.encode(to: encoder)
            }
        }
    }

    static func makeTranscriptPayload(
        job: JobInfo, transcript: String, transcriptFilename: String,
    ) -> TranscriptPayload {
        let (body, truncated) = truncateTranscript(transcript)
        return TranscriptPayload(
            jobID: job.jobID.uuidString,
            title: job.title,
            app: job.appName,
            meetingStart: isoString(job.meetingStartTime),
            participants: job.participants,
            participantEmails: job.participantEmails.isEmpty ? nil : job.participantEmails,
            transcriptFilename: transcriptFilename,
            transcript: body,
            truncated: truncated,
        )
    }

    /// Cut a transcript to `limit` UTF-8 bytes on a character boundary,
    /// keeping the end of the meeting: decisions, tasks and open questions are
    /// what a protocol is made from, and the participants travel in fields of
    /// their own. Returns the text and whether anything was removed.
    static func truncateTranscript(_ transcript: String, limit: Int = maxTranscriptBytes) -> (String, Bool) {
        if transcript.utf8.count <= limit { return (transcript, false) }
        var kept: [Character] = []
        var bytes = 0
        for character in transcript.reversed() {
            let size = String(character).utf8.count
            if bytes + size > limit { break }
            kept.append(character)
            bytes += size
        }
        return (String(kept.reversed()), true)
    }

    /// Send one transcript payload and settle its place in the outbox, exactly
    /// as `deliver` does for a protocol.
    static func deliverTranscript(
        _ payload: TranscriptPayload,
        to url: URL,
        outbox: ProtocolWebhookOutbox,
        session: URLSession = .shared,
        retryDelays: [Duration] = defaultRetryDelays,
        sleep: (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        notify: @Sendable (String) -> Void = { _ in },
    ) async -> Outcome {
        await deliver(
            .transcriptReady(payload), to: url, outbox: outbox, session: session,
            retryDelays: retryDelays, sleep: sleep, notify: notify,
        )
    }

    /// Fire-and-forget entry point for the pipeline when no protocol will be
    /// produced. `warn` runs on the main actor with a content-free message when
    /// delivery did not succeed.
    static func deliverTranscriptIfConfigured(
        job: JobInfo,
        transcriptFilename: String,
        transcript: String,
        url: URL? = configuredURL(),
        outbox: ProtocolWebhookOutbox = .shared,
        session: URLSession = .shared,
        warn: @escaping @MainActor (String) -> Void,
    ) {
        guard let url else { return }
        let shortID = PipelineJob.shortID(for: job.jobID)
        Task.detached(priority: .utility) {
            let payload = makeTranscriptPayload(
                job: job, transcript: transcript, transcriptFilename: transcriptFilename,
            )
            let outcome = await deliverTranscript(
                payload, to: url, outbox: outbox, session: session, notify: notifyUser,
            )
            switch outcome {
            case let .delivered(status):
                logger.info("[\(shortID, privacy: .public)] transcript_webhook_delivered status=\(status, privacy: .public)")

            case let .rejected(status):
                logger.error("[\(shortID, privacy: .public)] transcript_webhook_rejected status=\(status, privacy: .public)")
                await warn("Transcript webhook rejected (HTTP \(status))")

            case let .failed(reason):
                logger.error("[\(shortID, privacy: .public)] transcript_webhook_failed reason=\(reason, privacy: .public)")
                await warn("Transcript webhook not delivered yet; queued for retry")
            }
        }
    }
}
