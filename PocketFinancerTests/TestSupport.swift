import Foundation
import SwiftData
import XCTest

@testable import PocketFinancer

enum TestFixtures {
    static let receivedAt = Date(timeIntervalSince1970: 1_785_955_200)
    static let validBody =
        "HDFC Bank: Rs.500.00 debited from a/c XXXXXX0000 on 05-08-2026 at Demo Store."

    static func strictPostedOutput(
        for source: String,
        amountText: String = "Rs.500.00",
        amountValue: String = "500.00",
        currency: String = "INR",
        direction: String = "debit",
        directionText: String = "debited",
        accountReference: String = "XXXXXX0000",
        accountText: String = "XXXXXX0000",
        counterpartyText: String? = "Demo Store"
    ) throws -> String {
        func span(_ text: String) throws -> (start: Int, end: Int, text: String) {
            let range = try XCTUnwrap(source.range(of: text))
            let start = source[..<range.lowerBound].unicodeScalars.count
            let end = start + source[range].unicodeScalars.count
            return (start, end, text)
        }
        let amount = try span(amountText)
        let dir = try span(directionText)
        let account = try span(accountText)
        let counterparty = try counterpartyText.map { try span($0) }
        return try FoundationSmsExtractor.projectFlatExtraction(
            FlatSmsExtraction(
                decision: "posted",
                amountValue: amountValue,
                amountCurrency: currency,
                amountStart: amount.start,
                amountEnd: amount.end,
                amountText: amount.text,
                directionValue: direction,
                directionStart: dir.start,
                directionEnd: dir.end,
                directionText: dir.text,
                accountReference: accountReference,
                accountStart: account.start,
                accountEnd: account.end,
                accountText: account.text,
                counterpartyValue: counterparty?.text ?? "",
                counterpartyStart: counterparty?.start ?? 0,
                counterpartyEnd: counterparty?.end ?? 0,
                counterpartyText: counterparty?.text ?? ""
            )
        )
    }

    @MainActor
    static func makeAlert(
        body: String = validBody,
        sender: String = "SYNTH",
        receivedAt: Date = receivedAt,
        origin: AlertOrigin = .manual,
        sourceApplication: String? = "Tests"
    ) -> InboxAlert {
        InboxAlert(
            sourceIdentity: "synthetic-\(UUID().uuidString)",
            contentDigest: CanonicalJSON.sha256(body),
            origin: origin,
            sourceApplication: sourceApplication,
            sender: sender,
            rawBody: body,
            receivedAt: receivedAt
        )
    }

    @MainActor
    static func makeSnapshot(
        context: ModelContext,
        alert: InboxAlert,
        trigger: String = "test",
        primaryCurrency: String = "INR",
        enabledProfiles: [String] = ["core-en", "india"],
        extractorEligibilityOverride: Bool? = true,
        now: Date = receivedAt
    ) throws -> SmsOperationSnapshot {
        try SmsOperationSnapshotFactory(context: context).create(
            sourceAlertID: alert.id,
            trigger: trigger,
            primaryCurrency: primaryCurrency,
            enabledProfiles: enabledProfiles,
            extractorEligibilityOverride: extractorEligibilityOverride,
            now: now
        )
    }

    static func usePrimaryCurrency(_ code: String?) -> () -> Void {
        let defaults = UserDefaults.standard
        let previousCode = defaults.object(forKey: PrimaryCurrencySettings.key)
        let previousConfirmation = defaults.object(
            forKey: PrimaryCurrencySettings.confirmationKey
        )
        defaults.removeObject(forKey: PrimaryCurrencySettings.key)
        defaults.removeObject(forKey: PrimaryCurrencySettings.confirmationKey)
        if let code {
            PrimaryCurrencySettings.confirm(code)
        }
        return {
            defaults.removeObject(forKey: PrimaryCurrencySettings.key)
            defaults.removeObject(forKey: PrimaryCurrencySettings.confirmationKey)
            if let previousCode {
                defaults.set(previousCode, forKey: PrimaryCurrencySettings.key)
            }
            if let previousConfirmation {
                defaults.set(
                    previousConfirmation,
                    forKey: PrimaryCurrencySettings.confirmationKey
                )
            }
        }
    }

    @MainActor
    static func assertThrowsErrorAsync(
        _ expression: () async throws -> Void,
        verify: (Error) -> Void
    ) async {
        do {
            try await expression()
            XCTFail("Expected async expression to throw")
        } catch {
            verify(error)
        }
    }
}

nonisolated struct FixedSmsExtractor: FoundationSmsExtracting {
    let rawOutput: String
    let completion: String

    init(rawOutput: String, completion: String = "complete") {
        self.rawOutput = rawOutput
        self.completion = completion
    }

    func extract(requestJSON: String) async throws -> DirectSelectorResponse {
        DirectSelectorResponse(
            rawOutput: rawOutput,
            runtimeProfileJSON: SmsFlatExtractionProjector.runtimeProfileJSON,
            requestJSON: requestJSON,
            completion: completion
        )
    }
}

nonisolated struct ThrowingSmsExtractor: FoundationSmsExtracting {
    let error: any Error & Sendable

    func extract(requestJSON _: String) async throws -> DirectSelectorResponse {
        throw error
    }
}
