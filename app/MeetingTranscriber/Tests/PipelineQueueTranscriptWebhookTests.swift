import Foundation
@testable import MeetingTranscriber
import XCTest

/// What the pipeline hands the webhook when a transcript exists but no
/// protocol will: the raw transcript, so the meeting still leaves the Mac.
/// The webhook itself is a recorder here — nothing leaves the process.
@MainActor
// swiftlint:disable:next attributes balanced_xctest_lifecycle
final class PipelineQueueTranscriptWebhookTests: XCTestCase {
    // swiftlint:disable:next implicitly_unwrapped_optional
    private var tmpDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        tmpDir = try makeTempDirectory(prefix: "pipeline_transcript_webhook")
    }

    /// Records what the pipeline would have sent.
    private final class RecordingWebhook: WebhookDispatching, @unchecked Sendable {
        struct Transcript: Equatable {
            let job: ProtocolWebhook.JobInfo
            let filename: String
            let text: String
        }

        private let lock = NSLock()
        private var protocols: [String] = []
        private var transcripts: [Transcript] = []

        var sentProtocols: [String] {
            lock.withLock { protocols }
        }

        var sentTranscripts: [Transcript] {
            lock.withLock { transcripts }
        }

        func protocolReady(
            job _: ProtocolWebhook.JobInfo,
            protocolPath: URL,
            warn _: @escaping @MainActor (String) -> Void,
        ) {
            lock.withLock { protocols.append(protocolPath.lastPathComponent) }
        }

        func transcriptReady(
            job: ProtocolWebhook.JobInfo,
            transcriptFilename: String,
            transcript: String,
            warn _: @escaping @MainActor (String) -> Void,
        ) {
            lock.withLock {
                transcripts.append(Transcript(job: job, filename: transcriptFilename, text: transcript))
            }
        }
    }

    private let transcript = "[00:00] Me: привет\n[00:05] Me: проверим вебхук"

    private func makeQueue(
        protocolGenerator: @escaping () -> (any ProtocolGenerating)?,
        webhook: RecordingWebhook,
    ) throws -> (PipelineQueue, PipelineJob, URL) {
        let root = tmpDir.appendingPathComponent("output", isDirectory: true)
        let protocols = root.appendingPathComponent("protocols", isDirectory: true)
        try FileManager.default.createDirectory(at: protocols, withIntermediateDirectories: true)
        let queue = PipelineQueue(
            engine: MockEngine(),
            diarizationFactory: { MockDiarization() },
            protocolGeneratorFactory: protocolGenerator,
            outputDir: root,
            logDir: tmpDir,
            micLabel: "Me",
            inFlightRuns: InFlightRunRegistry(),
            webhook: webhook,
        )
        var job = PipelineJob(
            meetingTitle: "Проверка вебхука", appName: "Zoom",
            mixPath: tmpDir.appendingPathComponent("unused.wav"), appPath: nil, micPath: nil, micDelay: 0,
        )
        job.transcriptPath = protocols.appendingPathComponent("20261030_1200_proverka.txt")
        job.namingSlug = "20261030_1200_proverka"
        queue.insertJobForTesting(job)
        return (queue, job, protocols)
    }

    func testNoGeneratorSendsTheTranscriptInsteadOfAProtocol() async throws {
        let webhook = RecordingWebhook()
        let (queue, job, protocols) = try makeQueue(protocolGenerator: { nil }, webhook: webhook)

        await queue.generateProtocol(
            jobID: job.id, transcript: transcript, title: job.meetingTitle, protocolsDir: protocols,
        )

        XCTAssertTrue(webhook.sentProtocols.isEmpty)
        let sent = try XCTUnwrap(webhook.sentTranscripts.first)
        XCTAssertEqual(sent.text, transcript)
        XCTAssertEqual(sent.filename, "20261030_1200_proverka.txt")
        XCTAssertEqual(sent.job.jobID, job.id)
        XCTAssertEqual(sent.job.title, "Проверка вебхука")
        XCTAssertEqual(sent.job.appName, "Zoom")
    }

    func testFailedGenerationStillSendsTheTranscript() async throws {
        let protocolGen = MockProtocolGen()
        protocolGen.shouldThrow = true
        let webhook = RecordingWebhook()
        let (queue, job, protocols) = try makeQueue(protocolGenerator: { protocolGen }, webhook: webhook)

        await queue.generateProtocol(
            jobID: job.id, transcript: transcript, title: job.meetingTitle, protocolsDir: protocols,
        )

        XCTAssertTrue(protocolGen.generateCalled, "test premise: generation was attempted")
        XCTAssertTrue(webhook.sentProtocols.isEmpty)
        let sent = try XCTUnwrap(webhook.sentTranscripts.first)
        XCTAssertEqual(sent.text, transcript)
        let after = try XCTUnwrap(queue.jobs.first { $0.id == job.id })
        XCTAssertTrue(after.warnings.contains { $0.contains("generation failed") }, "\(after.warnings)")
    }

    func testAWrittenProtocolIsSentAndNoTranscript() async throws {
        let protocolGen = MockProtocolGen()
        let webhook = RecordingWebhook()
        let (queue, job, protocols) = try makeQueue(protocolGenerator: { protocolGen }, webhook: webhook)

        await queue.generateProtocol(
            jobID: job.id, transcript: transcript, title: job.meetingTitle, protocolsDir: protocols,
        )

        XCTAssertEqual(webhook.sentTranscripts.count, 0, "the receiver builds no protocol when one was written here")
        let sent = try XCTUnwrap(webhook.sentProtocols.first)
        XCTAssertTrue(sent.hasSuffix(".md"), sent)
        let after = try XCTUnwrap(queue.jobs.first { $0.id == job.id })
        XCTAssertNotNil(after.protocolPath)
    }
}
