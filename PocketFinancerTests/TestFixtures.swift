import Foundation
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
}
