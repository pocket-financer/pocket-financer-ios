import Foundation
import SwiftData
import XCTest

@testable import PocketFinancer

@MainActor
final class StructuralSmsAnalyzerTests: XCTestCase {
    func testAnalyzerParsesExactMinorUnitsAndBlocksExpectedRefund() throws {
        let (analysis, _) = try analyze("Refund of INR 1,234.50 is expected tomorrow")

        XCTAssertEqual(
            analysis.candidates.first(where: { $0.kind == .amount })?.value["minor_units"],
            "123450"
        )
        XCTAssertTrue(analysis.reasonCodes.contains("expected_refund_not_posted"))
        XCTAssertEqual(analysis.completedEventCount, 0)
    }

    func testAnalyzerExtractsAmountDirectionAccountVpaAndCounterpartyAndFiltersStopWords() throws {
        let body =
            "Rs.1,23,456.78 debited from a/c XXXXXX1234 via UPI user.name@synthbank, at Demo Store; "
            + "to your account, card ending 9876 available balance INR 5,000.00."
        let (analysis, _) = try analyze(body)

        let amounts = analysis.candidates.filter { $0.kind == .amount }
        XCTAssertEqual(amounts.map { $0.value["minor_units"] }, ["12345678", "500000"])
        XCTAssertEqual(amounts.first?.value["currency"], "INR")
        XCTAssertEqual(amounts.first?.value["currency_provenance"], "explicit_unambiguous_symbol_or_marker")
        XCTAssertEqual(amounts.last?.value["currency_provenance"], "explicit_code")

        let directions = analysis.candidates.filter { $0.kind == .direction }
        XCTAssertEqual(directions.count, 1)
        XCTAssertEqual(directions.first?.value["direction"], "debit")
        XCTAssertEqual(analysis.completedEventCount, 1)

        let accounts = analysis.candidates.filter { $0.kind == .account && !$0.explicitlyAbsent }
        let accountTypes = Set(accounts.compactMap { $0.value["account_type"] })
        XCTAssertEqual(accountTypes, Set(["bank_account", "card", "vpa"]))

        let counterparties = analysis.candidates.filter { $0.kind == .counterparty && !$0.explicitlyAbsent }
        XCTAssertTrue(counterparties.contains { $0.value["surface"] == "Demo Store" })
        XCTAssertFalse(counterparties.contains { $0.value["surface"]?.lowercased() == "your" })

        XCTAssertTrue(analysis.reasonCodes.contains("amount_candidate_present"))
        XCTAssertTrue(analysis.reasonCodes.contains("completed_direction_candidate_present"))
        XCTAssertTrue(analysis.reasonCodes.contains("balance_information"))

        let canonical = try analysis.canonicalJSON
        let decoded = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(canonical.utf8)) as? [String: Any]
        )
        XCTAssertEqual(decoded["contract"] as? String, "pocketfinancer.sms-analysis/2")
        XCTAssertEqual(decoded["primary_currency"] as? String, "INR")
        XCTAssertEqual(decoded["profile_id"] as? String, "core-en+india")
    }

    func testBlockingClauseSuppressesOnlyBlockedClauseDirectionAndPreservesCompletedClause() throws {
        let body =
            "INR 200.00 was debited from account XX1234 at Demo Store, "
            + "but INR 50.00 will be credited tomorrow."
        let (analysis, _) = try analyze(body)

        XCTAssertEqual(analysis.clauses.count, 2)
        XCTAssertEqual(analysis.completedEventCount, 1)
        XCTAssertEqual(
            analysis.candidates.filter { $0.kind == .direction }.map { $0.value["direction"] },
            ["debit"]
        )
        XCTAssertTrue(analysis.reasonCodes.contains("pending_event"))
        XCTAssertEqual(analysis.clauseAnnotations.first?.states, ["completed"])
        XCTAssertEqual(analysis.clauseAnnotations.last?.states, ["pending"])
    }

    func testAnalyzerRecognizesNonPostedCueCategories() throws {
        let cases: [(String, String)] = [
            ("Payment of INR 100.00 failed for card XX1234.", "non_posted_failure"),
            ("No money was debited from a/c XX1234.", "negated_movement"),
            ("Minimum due INR 500.00 due date 10-08-2026.", "amount_due"),
            ("Collect request for INR 300.00 approve in UPI app.", "request_or_authorization"),
            ("Authorization hold of INR 100.00 on card XX1234.", "authorization_or_hold_not_posted"),
            ("Statement generated for account XX1234.", "administrative"),
            ("Limited time cashback offer on card XX1234.", "promotion"),
            ("Your verification code is 482910.", "credential_otp"),
        ]

        for (body, expectedReason) in cases {
            let (analysis, _) = try analyze(body)
            XCTAssertTrue(analysis.reasonCodes.contains(expectedReason), expectedReason)
        }
    }

    func testClauseSegmenterAndStructuralViewHandleUnicodeAndMultiScalarCasefold() {
        XCTAssertTrue(StructuralClauseSegmenter.clauses(in: "").isEmpty)

        let segmented = StructuralClauseSegmenter.clauses(
            in: "Line one.\nLine two; line three! Part four however part five."
        )
        XCTAssertEqual(
            segmented.map(\.evidence.text),
            ["Line one.", "Line two;", "line three!", "Part four", "part five."]
        )

        let view = SmsStructuralView("Straße  \t INR 10.00")
        XCTAssertEqual(view.normalized, "strasse inr 10.00")
        let match = view.matches(#"strasse"#).first
        let evidence = match?.evidence()
        XCTAssertEqual(evidence?.text, "Straße")
        XCTAssertEqual(evidence?.startCharacter, 0)
        XCTAssertEqual(evidence?.endCharacter, 6)
    }

    private func analyze(_ body: String) throws -> (SmsAnalysis, SmsOperationSnapshot) {
        let database = try AppDatabase(inMemory: true)
        let context = database.container.mainContext
        let alert = TestFixtures.makeAlert(body: body)
        context.insert(alert)
        try context.save()
        let snapshot = try TestFixtures.makeSnapshot(context: context, alert: alert)
        let analysis = try StructuralSmsAnalyzer().analyze(source: alert.rawBody, operation: snapshot)
        return (analysis, snapshot)
    }
}
