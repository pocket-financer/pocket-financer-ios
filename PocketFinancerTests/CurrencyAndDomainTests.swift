import Foundation
import XCTest

@testable import PocketFinancer

final class CurrencyAndDomainTests: XCTestCase {
    @MainActor
    func testINRFormattingKeepsIndianDigitGroupingAndHandlesZeroDecimalJPY() {
        let formattedINR = CurrencyFormatter.string(
            minorUnits: Int64(12_345_678),
            currencyCode: "INR"
        )
        XCTAssertTrue(formattedINR.contains("1,23,456.78"))

        let formattedJPY = CurrencyFormatter.string(
            minorUnits: Int64(1250),
            currencyCode: "JPY"
        )
        XCTAssertTrue(formattedJPY.contains("1,250") || formattedJPY.contains("1250"))
        XCTAssertFalse(formattedJPY.contains("."))
    }

    @MainActor
    func testFormatsAggregateBeyondInt64WithoutOverflow() {
        let aggregateMinorUnits = Decimal(Int64.max) + Decimal(Int64.max)

        let formatted = CurrencyFormatter.string(
            minorUnits: aggregateMinorUnits,
            currencyCode: "INR"
        )

        XCTAssertFalse(formatted.isEmpty)
        XCTAssertTrue(formatted.contains("₹") || formatted.contains("INR"))
    }

    @MainActor
    func testParsesAndEditsMajorUnitsWithoutRounding() {
        XCTAssertEqual(
            CurrencyFormatter.minorUnits(
                fromMajorUnitText: "100.50",
                currencyCode: "INR",
                locale: Locale(identifier: "en_IN")
            ),
            10_050
        )
        XCTAssertEqual(
            CurrencyFormatter.minorUnits(
                fromMajorUnitText: "100,50",
                currencyCode: "EUR",
                locale: Locale(identifier: "de_DE")
            ),
            10_050
        )
        XCTAssertEqual(
            CurrencyFormatter.minorUnits(
                fromMajorUnitText: "500",
                currencyCode: "JPY",
                locale: Locale(identifier: "en_US")
            ),
            500
        )
        XCTAssertNil(
            CurrencyFormatter.minorUnits(fromMajorUnitText: "500.5", currencyCode: "JPY")
        )
        XCTAssertNil(
            CurrencyFormatter.minorUnits(fromMajorUnitText: "100.501", currencyCode: "INR")
        )
        XCTAssertNil(
            CurrencyFormatter.minorUnits(fromMajorUnitText: "0", currencyCode: "INR")
        )
        XCTAssertNil(
            CurrencyFormatter.minorUnits(fromMajorUnitText: "-1", currencyCode: "INR")
        )
        XCTAssertNil(
            CurrencyFormatter.minorUnits(fromMajorUnitText: "100", currencyCode: "ZZZ")
        )
        XCTAssertEqual(
            CurrencyFormatter.editableMajorUnits(minorUnits: 12_345, currencyCode: "INR"),
            "123.45"
        )
        XCTAssertEqual(
            CurrencyFormatter.editableMajorUnits(minorUnits: 500, currencyCode: "JPY"),
            "500"
        )
    }

    @MainActor
    func testCurrencyProfileRegistryParsesExactMinorUnitsAndRejectsInvalidInputs() {
        XCTAssertEqual(
            CurrencyProfileRegistry.parse(
                number: "1,23,456.7",
                currency: "inr",
                provenance: "explicit_code"
            ),
            SmsParsedMoney(
                minorUnits: 12_345_670,
                currency: "INR",
                scale: 2,
                provenance: "explicit_code"
            )
        )
        let jpyMinorUnits = CurrencyProfileRegistry.parse(
            number: "2500",
            currency: "JPY",
            provenance: "explicit_code"
        )?.minorUnits
        XCTAssertEqual(jpyMinorUnits, 2500)
        XCTAssertNil(
            CurrencyProfileRegistry.parse(number: "2500.5", currency: "JPY", provenance: "explicit_code")
        )
        XCTAssertNil(
            CurrencyProfileRegistry.parse(number: "0.00", currency: "INR", provenance: "explicit_code")
        )
        XCTAssertNil(
            CurrencyProfileRegistry.parse(number: "10.00", currency: "XXX", provenance: "explicit_code")
        )
    }

    @MainActor
    func testPrimaryCurrencyRequiresExplicitConfirmationAndSelectsProfiles() {
        let restore = TestFixtures.usePrimaryCurrency(nil)
        defer { restore() }
        let defaults = UserDefaults.standard

        XCTAssertNil(PrimaryCurrencySettings.confirmedCode)
        XCTAssertEqual(PrimaryCurrencySettings.currentCode, "INR")
        XCTAssertEqual(PrimaryCurrencySettings.enabledProfiles, ["core-en", "india"])

        defaults.set("INR", forKey: PrimaryCurrencySettings.key)
        XCTAssertNil(PrimaryCurrencySettings.confirmedCode)

        PrimaryCurrencySettings.confirm("ZZZ")
        XCTAssertNil(PrimaryCurrencySettings.confirmedCode)

        PrimaryCurrencySettings.confirm("usd")
        XCTAssertEqual(PrimaryCurrencySettings.confirmedCode, "USD")
        XCTAssertEqual(PrimaryCurrencySettings.currentCode, "USD")
        XCTAssertEqual(PrimaryCurrencySettings.enabledProfiles, ["core-en"])
    }

    @MainActor
    func testAccountNormalizerHandlesBankAccountCardMissingSuffixAndSenderIndependence() {
        let account = AccountNormalizer.normalize(
            label: "a/c XXXXXX1234",
            sender: "AX-HDFCBK",
            body: "HDFC Bank alert"
        )
        XCTAssertEqual(
            account,
            NormalizedAccount(name: "HDFC Bank A/c XX1234", bank: "HDFC Bank", kind: .account, suffix: "1234")
        )

        let card = AccountNormalizer.normalize(
            label: "Card ending XX1234",
            sender: "AX-HDFCBK",
            body: "HDFC Bank alert"
        )
        XCTAssertEqual(
            card,
            NormalizedAccount(name: "HDFC Bank Card XX1234", bank: "HDFC Bank", kind: .card, suffix: "1234")
        )

        let lastRun = AccountNormalizer.normalize(
            label: "a/c XX123 to a/c XXXX9876",
            sender: "BANK",
            body: "Transaction alert"
        )
        XCTAssertEqual(lastRun.name, "A/c XX9876")
        XCTAssertEqual(lastRun.bank, "")
        XCTAssertEqual(lastRun.suffix, "9876")

        let missingSuffix = AccountNormalizer.normalize(
            label: "account",
            sender: "SBI",
            body: "SBI transaction"
        )
        XCTAssertEqual(missingSuffix.name, "SBI Account")
        XCTAssertEqual(missingSuffix.kind, .unknown)
        XCTAssertNil(missingSuffix.suffix)

        let first = AccountNormalizer.normalize(
            label: "a/c XXXXXX1234",
            sender: "AX-HDFCBK",
            body: "Transaction alert"
        )
        let second = AccountNormalizer.normalize(
            label: "a/c XXXXXX1234",
            sender: "+919999999999",
            body: "Transaction alert"
        )
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.name, "A/c XX1234")
        XCTAssertTrue(first.bank.isEmpty)
    }

    @MainActor
    func testAlertSourceIdentityFingerprintAndSenderIndependentContentDigest() {
        let date = Date(timeIntervalSince1970: 1_000)
        let first = AlertSourceIdentity.fingerprint(
            sender: " ax-hdfcbk ",
            body: "Rs 500 debited",
            receivedAt: date,
            sourceApplication: "Messages"
        )
        let normalized = AlertSourceIdentity.fingerprint(
            sender: "AX-HDFCBK",
            body: "Rs 500 debited",
            receivedAt: date,
            sourceApplication: "Messages"
        )
        let changedBody = AlertSourceIdentity.fingerprint(
            sender: "AX-HDFCBK",
            body: "Rs 500 debited ",
            receivedAt: date,
            sourceApplication: "Messages"
        )

        XCTAssertEqual(first, normalized)
        XCTAssertNotEqual(first, changedBody)
        XCTAssertEqual(first.count, 64)
        XCTAssertFalse(AlertSourceIdentity.opaqueCandidateKey(sourceIdentity: first).contains("HDFC"))

        let digestA = AlertSourceIdentity.contentDigest(
            sender: "AX-BANK",
            body: "Caf\u{00E9}\r\nRs 500 debited "
        )
        let digestB = AlertSourceIdentity.contentDigest(
            sender: "+919999999999",
            body: "  Cafe\u{0301}\nRs 500 debited"
        )
        XCTAssertEqual(digestA, digestB)
        XCTAssertEqual(digestA.count, 64)
    }
}
