import Foundation
import XCTest

@testable import PocketFinancer

final class DiagnosticsAndRuntimeTests: XCTestCase {
    @MainActor
    func testModelDiagnosticsCoversEveryAvailabilityStateAndLocaleProbe() async {
        let probes = localeSupportProbes(currentSupported: true)
        let ready = ModelDiagnostics.makeDiagnostic(
            availability: .available,
            localeIdentifier: "en-US",
            localeWasSupported: true,
            localeSupportProbes: probes,
            supportedLanguageIdentifiers: ["hi", "en", "en"]
        )
        XCTAssertTrue(ready.isReady)
        XCTAssertEqual(ready.localeIdentifier, "en-US")
        XCTAssertTrue(ready.localeWasSupported)
        XCTAssertEqual(ready.formattingLocaleIdentifier, "en_IN")
        XCTAssertEqual(ready.supportedLanguageIdentifiers, ["en", "hi"])
        XCTAssertEqual(ready.supportedLanguageSummary, "en, hi")
        XCTAssertEqual(ModelDiagnostics.modelProcessingLocaleIdentifier, "en-US")

        let unsupported = ModelDiagnostics.makeDiagnostic(
            availability: .available,
            localeIdentifier: "zz_IN",
            localeWasSupported: false,
            localeSupportProbes: localeSupportProbes(currentSupported: false),
            supportedLanguageIdentifiers: ["en", "hi"]
        )
        XCTAssertFalse(unsupported.isReady)
        XCTAssertEqual(unsupported.title, "Model processing language unsupported")
        XCTAssertTrue(unsupported.detail.contains("iPhone and Siri languages"))
        XCTAssertTrue(unsupported.detail.contains("region can remain India"))

        let notReady = ModelDiagnostics.makeDiagnostic(
            availability: .modelNotReady,
            localeIdentifier: "en-US",
            localeWasSupported: true,
            localeSupportProbes: probes,
            supportedLanguageIdentifiers: []
        )
        XCTAssertFalse(notReady.isReady)
        XCTAssertTrue(notReady.detail.contains("does not provide download progress"))
        XCTAssertEqual(notReady.supportedLanguageSummary, "Not reported by the system model right now")

        let ineligible = ModelDiagnostics.makeDiagnostic(
            availability: .deviceNotEligible,
            localeIdentifier: "en-US",
            localeWasSupported: true,
            localeSupportProbes: probes,
            supportedLanguageIdentifiers: []
        )
        XCTAssertFalse(ineligible.isReady)
        XCTAssertEqual(ineligible.title, "Device not eligible")

        let disabled = ModelDiagnostics.makeDiagnostic(
            availability: .appleIntelligenceNotEnabled,
            localeIdentifier: "en-US",
            localeWasSupported: true,
            localeSupportProbes: probes,
            supportedLanguageIdentifiers: []
        )
        XCTAssertFalse(disabled.isReady)
        XCTAssertEqual(disabled.title, "Apple Intelligence is off")

        let unknown = ModelDiagnostics.makeDiagnostic(
            availability: .unknownUnavailable,
            localeIdentifier: "en-US",
            localeWasSupported: true,
            localeSupportProbes: probes,
            supportedLanguageIdentifiers: []
        )
        XCTAssertFalse(unknown.isReady)
        XCTAssertEqual(unknown.title, "Model unavailable")

        let identifiers = ModelDiagnostics.languageIdentifiers([
            Locale.Language(identifier: "en_US"),
            Locale.Language(identifier: "hi_Deva_IN"),
            Locale.Language(identifier: "en_GB"),
        ])
        XCTAssertEqual(identifiers, identifiers.sorted())
        XCTAssertEqual(Set(identifiers).count, identifiers.count)
        XCTAssertTrue(identifiers.contains("en"))
        XCTAssertTrue(identifiers.contains("hi"))

        XCTAssertEqual(
            ModelDiagnostics.makeLocaleSupportProbes(
                modelLocale: Locale(identifier: "en-US"),
                modelLocaleWasSupported: true,
                formattingLocale: Locale(identifier: "en_IN")
            ),
            probes
        )

        let calls = DiagnosticCallRecorder()
        let loaded = await ModelDiagnostics.loadCurrent(
            processingLocale: Locale(identifier: "en-US"),
            using: { _ in
                calls.record()
                return ready
            }
        )
        XCTAssertEqual(loaded, ready)
        XCTAssertEqual(calls.count, 1)
    }

    @MainActor
    func testAlertProcessingDiagnosticsCoversTitlesDurationsAndSafeCodes() {
        for status in AlertStatus.allCases {
            XCTAssertFalse(AlertProcessingDiagnostics.statusTitle(status).isEmpty)
        }
        for origin in AlertOrigin.allCases {
            XCTAssertFalse(AlertProcessingDiagnostics.originTitle(origin).isEmpty)
        }

        XCTAssertEqual(
            AlertProcessingDiagnostics.presentation(for: "model_timed_out"),
            ProcessingCodePresentation(
                title: "Attempt timed out",
                detail:
                    "Pocket Financer requested cancellation after 60 seconds. "
                    + "Apple's model may take additional time to release the local request."
            )
        )
        XCTAssertEqual(
            AlertProcessingDiagnostics.presentation(for: "tombstoned_excluded").title,
            "Excluded before model invocation"
        )
        XCTAssertEqual(
            AlertProcessingDiagnostics.presentation(for: "prefilter_otp_verification").title,
            "Excluded by local prefilter"
        )
        XCTAssertEqual(
            AlertProcessingDiagnostics.presentation(for: "tombstoned_none").title,
            "No completed transaction"
        )
        XCTAssertEqual(
            AlertProcessingDiagnostics.presentation(for: "persistence_all_gates_passed").title,
            "Saved automatically"
        )
        XCTAssertEqual(
            AlertProcessingDiagnostics.presentation(for: "account_resolution_unresolved").title,
            "Account not yet linked"
        )
        XCTAssertEqual(
            AlertProcessingDiagnostics.presentation(for: "account_resolution_ambiguous").title,
            "Multiple accounts matched"
        )
        XCTAssertEqual(
            AlertProcessingDiagnostics.presentation(for: "duplicate_possible").title,
            "Possible duplicate detected"
        )
        XCTAssertEqual(
            AlertProcessingDiagnostics.presentation(for: "unrecognized_synthetic_code").title,
            "Recorded processing code"
        )

        XCTAssertEqual(AlertProcessingDiagnostics.durationText(0.4), "Under 1 second")
        XCTAssertEqual(AlertProcessingDiagnostics.durationText(12.34), "12.3 seconds")
        XCTAssertEqual(AlertProcessingDiagnostics.durationText(65), "1m 5s")

        let start = Date(timeIntervalSince1970: 100)
        XCTAssertNil(
            AlertProcessingDiagnostics.attemptDuration(
                lastAttemptAt: start,
                updatedAt: start.addingTimeInterval(2),
                status: .processing
            )
        )
        XCTAssertNil(
            AlertProcessingDiagnostics.attemptDuration(
                lastAttemptAt: nil,
                updatedAt: start,
                status: .needsReview
            )
        )
        XCTAssertEqual(
            AlertProcessingDiagnostics.attemptDuration(
                lastAttemptAt: start,
                updatedAt: start.addingTimeInterval(-2),
                status: .needsReview
            ),
            0
        )
        XCTAssertEqual(
            AlertProcessingDiagnostics.attemptDuration(
                lastAttemptAt: start,
                updatedAt: start.addingTimeInterval(4.5),
                status: .imported
            ),
            4.5
        )
    }

    func testExecutionGateSerializesHandlesCancellationAndReleasesAfterFailure() async throws {
        let gate = FoundationModelExecutionGate()
        let probe = GateConcurrencyProbe()

        async let first: Void = gate.withPermit { await probe.run() }
        async let second: Void = gate.withPermit { await probe.run() }
        async let third: Void = gate.withPermit { await probe.run() }
        _ = try await (first, second, third)
        let maximumActive = await probe.maximumActive
        XCTAssertEqual(maximumActive, 1)

        let firstAcquired = GateAsyncLatch()
        let releaseFirst = GateAsyncLatch()
        let holder = Task {
            try await gate.withPermit {
                await firstAcquired.open()
                await releaseFirst.wait()
                return 1
            }
        }
        await firstAcquired.wait()

        let cancelled = Task {
            try await gate.withPermit { 2 }
        }
        try await Task.sleep(for: .milliseconds(10))
        cancelled.cancel()

        let following = Task {
            try await gate.withPermit { 3 }
        }
        await releaseFirst.open()

        let holderValue = try await holder.value
        XCTAssertEqual(holderValue, 1)
        do {
            _ = try await cancelled.value
            XCTFail("Expected queued operation to be cancelled")
        } catch is CancellationError {
            // Expected: the following waiter must still acquire the permit.
        }
        let followingValue = try await following.value
        XCTAssertEqual(followingValue, 3)

        do {
            _ = try await gate.withPermit { () async throws -> Int in
                throw TransactionParserError.generationFailed
            }
            XCTFail("Expected thrown error to propagate")
        } catch let error as TransactionParserError {
            XCTAssertEqual(error, .generationFailed)
        }
        let afterError = try await gate.withPermit { 42 }
        XCTAssertEqual(afterError, 42)
    }

    @MainActor
    func testModelSelfTestPassesAndFailsClosedAcrossExtractorOutcomes() async throws {
        let receivedAt = Date(timeIntervalSince1970: 1_785_955_200.125)
        let validOutput = try selfTestPostedOutput()

        let passed = await ModelSelfTestService.run(
            extractor: FixedSmsExtractor(rawOutput: validOutput),
            extractorEligibilityOverride: true,
            receivedAt: receivedAt
        )
        XCTAssertTrue(passed.passed)
        XCTAssertEqual(passed.outcome, .passed)
        XCTAssertEqual(passed.contractVersion, "pocketfinancer.sms-extractor-input/1")
        XCTAssertEqual(passed.generationMode, "DIRECT_NON_THINKING")
        XCTAssertEqual(passed.outputCompletion, "complete")
        XCTAssertEqual(passed.syntheticBody, ModelSelfTestService.syntheticBody)
        XCTAssertEqual(passed.syntheticSender, ModelSelfTestService.syntheticSender)
        XCTAssertEqual(passed.receivedAt, receivedAt)
        XCTAssertEqual(passed.settlement, "retained_for_review")
        XCTAssertNil(passed.failure)
        XCTAssertNotNil(passed.analysisJSON)
        XCTAssertTrue(passed.exactRequest.contains("sms-extractor-input/1"))
        XCTAssertTrue(passed.exactOutput?.contains(#""decision":"posted""#) == true)
        XCTAssertGreaterThanOrEqual(passed.completedAt, passed.startedAt)
        XCTAssertGreaterThanOrEqual(passed.elapsed, 0)
        XCTAssertEqual(passed.apiLimitations, ModelSelfTestService.apiLimitations)
        XCTAssertTrue(passed.apiLimitations.contains { $0.metric.localizedCaseInsensitiveContains("token") })
        XCTAssertTrue(passed.apiLimitations.contains { $0.metric.localizedCaseInsensitiveContains("reasoning") })

        let unavailable = await ModelSelfTestService.run(
            extractor: ThrowingSmsExtractor(error: TransactionParserError.modelUnavailable(.modelNotReady)),
            extractorEligibilityOverride: true,
            receivedAt: TestFixtures.receivedAt
        )
        XCTAssertFalse(unavailable.passed)
        XCTAssertEqual(unavailable.outcome, .failed)
        XCTAssertEqual(unavailable.settlement, "retained_for_review")
        XCTAssertEqual(unavailable.outputCompletion, "failed")
        XCTAssertNil(unavailable.exactOutput)
        XCTAssertEqual(unavailable.failure?.safeCode, "model_modelNotReady")
        XCTAssertEqual(unavailable.failure?.isRetryable, true)
        XCTAssertTrue(unavailable.summary.localizedCaseInsensitiveContains("did not produce"))

        let ineligible = await ModelSelfTestService.run(
            extractor: FixedSmsExtractor(rawOutput: validOutput),
            extractorEligibilityOverride: false,
            receivedAt: TestFixtures.receivedAt
        )
        XCTAssertFalse(ineligible.passed)
        XCTAssertEqual(ineligible.settlement, "retained_for_review")
        XCTAssertEqual(ineligible.failure?.safeCode, "runtime_unavailable")

        let mismatchedEvidence = await ModelSelfTestService.run(
            extractor: FixedSmsExtractor(
                rawOutput: validOutput.replacingOccurrences(of: #""text":"XXXXXX0000""#, with: #""text":"XX9999""#)
            ),
            extractorEligibilityOverride: true,
            receivedAt: TestFixtures.receivedAt
        )
        XCTAssertFalse(mismatchedEvidence.passed)
        XCTAssertEqual(mismatchedEvidence.failure?.safeCode, "extractor_evidence_mismatch")
        XCTAssertEqual(mismatchedEvidence.failure?.isRetryable, false)

        let invalidReference = await ModelSelfTestService.run(
            extractor: FixedSmsExtractor(
                rawOutput: validOutput.replacingOccurrences(
                    of: #""reference":"XXXXXX0000""#,
                    with: #""reference":"XX9999""#
                )
            ),
            extractorEligibilityOverride: true,
            receivedAt: TestFixtures.receivedAt
        )
        XCTAssertFalse(invalidReference.passed)
        XCTAssertEqual(invalidReference.failure?.safeCode, "extractor_account_reference_invalid")
        XCTAssertEqual(invalidReference.failure?.isRetryable, false)

        let nonTransaction = await ModelSelfTestService.run(
            extractor: FixedSmsExtractor(rawOutput: #"{"decision":"none"}"#),
            extractorEligibilityOverride: true,
            receivedAt: TestFixtures.receivedAt
        )
        XCTAssertFalse(nonTransaction.passed)
        XCTAssertEqual(nonTransaction.settlement, "discarded")
        XCTAssertEqual(nonTransaction.failure?.safeCode, "extractor_none")
    }

    private func selfTestPostedOutput() throws -> String {
        try TestFixtures.strictPostedOutput(
            for: ModelSelfTestService.syntheticBody,
            amountText: "INR 500.00",
            amountValue: "500.00",
            currency: "INR",
            direction: "debit",
            directionText: "paid",
            accountReference: "XXXXXX0000",
            accountText: "XXXXXX0000",
            counterpartyText: "Demo Store"
        )
    }

    private func localeSupportProbes(currentSupported: Bool) -> [ModelLocaleSupportProbe] {
        [
            ModelLocaleSupportProbe(
                label: "Model processing locale",
                localeIdentifier: "en-US",
                isSupported: currentSupported
            ),
            ModelLocaleSupportProbe(
                label: "Phone formatting locale",
                localeIdentifier: "en_IN",
                isSupported: nil
            ),
        ]
    }
}

private final class DiagnosticCallRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedCount = 0

    var count: Int { lock.withLock { recordedCount } }

    func record() {
        lock.withLock { recordedCount += 1 }
    }
}

private actor GateConcurrencyProbe {
    private var active = 0
    private(set) var maximumActive = 0

    func run() async {
        active += 1
        maximumActive = max(maximumActive, active)
        try? await Task.sleep(for: .milliseconds(20))
        active -= 1
    }
}

private actor GateAsyncLatch {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending {
            waiter.resume()
        }
    }
}
