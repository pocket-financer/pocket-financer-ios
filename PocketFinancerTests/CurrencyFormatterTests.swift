import XCTest

@testable import PocketFinancer

final class CurrencyFormatterTests: XCTestCase {
    @MainActor
    func testINRFormattingKeepsIndianDigitGrouping() {
        let formatted = CurrencyFormatter.string(
            minorUnits: Int64(12_345_678),
            currencyCode: "INR"
        )

        XCTAssertTrue(formatted.contains("1,23,456.78"))
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
    func testParsesEditableMajorUnitsWithoutRounding() {
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
        XCTAssertNil(
            CurrencyFormatter.minorUnits(
                fromMajorUnitText: "100.501",
                currencyCode: "INR"
            )
        )
        XCTAssertNil(
            CurrencyFormatter.minorUnits(
                fromMajorUnitText: "-1",
                currencyCode: "INR"
            )
        )
    }
}
