import Foundation

/// The pipeline's seam for the webhook, so "did this meeting leave the Mac?"
/// is answerable in a test without a URL in the Keychain or a network.
///
/// Production wires `LiveWebhookDispatch`, which forwards to
/// `ProtocolWebhook`: the URL comes from the Keychain, an undelivered body
/// waits in the shared outbox, and failures only warn on the job. A test
/// injects a recorder instead.
protocol WebhookDispatching: Sendable {
    /// A protocol was written; send it.
    func protocolReady(
        job: ProtocolWebhook.JobInfo,
        protocolPath: URL,
        warn: @escaping @MainActor (String) -> Void,
    )

    /// The transcript was saved and no protocol will be produced; send the
    /// transcript for the receiver to build one. Nothing is sent when no
    /// webhook URL is configured.
    func transcriptReady(
        job: ProtocolWebhook.JobInfo,
        transcriptFilename: String,
        transcript: String,
        warn: @escaping @MainActor (String) -> Void,
    )
}

/// The production implementation. Delivery is off the job's critical path:
/// each call returns at once and settles the outbox on its own task.
struct LiveWebhookDispatch: WebhookDispatching {
    func protocolReady(
        job: ProtocolWebhook.JobInfo,
        protocolPath: URL,
        warn: @escaping @MainActor (String) -> Void,
    ) {
        ProtocolWebhook.deliverIfConfigured(job: job, protocolPath: protocolPath, warn: warn)
    }

    func transcriptReady(
        job: ProtocolWebhook.JobInfo,
        transcriptFilename: String,
        transcript: String,
        warn: @escaping @MainActor (String) -> Void,
    ) {
        ProtocolWebhook.deliverTranscriptIfConfigured(
            job: job, transcriptFilename: transcriptFilename, transcript: transcript, warn: warn,
        )
    }
}
