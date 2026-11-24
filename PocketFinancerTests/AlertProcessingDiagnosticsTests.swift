import XCTest

@testable import PocketFinancer

final class AlertProcessingDiagnosticsTests: XCTestCase {
    @MainActor
    func testExtractorPromptAndLocaleMatchUnifiedContract() throws {
        let prompt = try SmsContractAssets.extractorPrompt()

        XCTAssertTrue(prompt.contains("pocketfinancer.apple-fm-extractor-prompt/1"))
        XCTAssertTrue(prompt.contains(#""posted""#))
        XCTAssertEqual(ModelDiagnostics.modelProcessingLocaleIdentifier, "en-US")
    }

    @MainActor
    func testPrefilterDistinguishesTransactionsAndOtpRegardlessOfSender() {
        let valid = SmsPrefilter.evaluate(TestFixtures.validBody)
        let otp = SmsPrefilter.evaluate("Your OTP for card transaction is 482910. Do not share.")

        XCTAssertEqual(valid.decision, .pass)
        XCTAssertEqual(valid.reason, .eligible)
        XCTAssertEqual(otp.decision, .exclude)
        XCTAssertEqual(otp.reason, .otpVerification)
    }

    @MainActor
    func testSafeCodePresentationAndDurationFormatting() {
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
            AlertProcessingDiagnostics.presentation(for: "tombstoned_none").title,
            "No completed transaction"
        )
        XCTAssertEqual(
            AlertProcessingDiagnostics.presentation(for: "persistence_all_gates_passed").title,
            "Saved automatically"
        )
        XCTAssertEqual(AlertProcessingDiagnostics.durationText(0.4), "Under 1 second")
        XCTAssertEqual(AlertProcessingDiagnostics.durationText(12.34), "12.3 seconds")
        XCTAssertEqual(AlertProcessingDiagnostics.durationText(65), "1m 5s")
    }

    @MainActor
    func testAttemptDurationIsUnavailableWhileProcessingAndNeverNegative() {
        let start = Date(timeIntervalSince1970: 100)

        XCTAssertNil(
            AlertProcessingDiagnostics.attemptDuration(
                lastAttemptAt: start,
                updatedAt: start.addingTimeInterval(2),
                status: .processing
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
    }
}
