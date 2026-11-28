import Foundation
import SwiftUI
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
    func testPrimaryCurrencySnapshotResetAndDrainPolicyRequireConfirmedCurrency() {
        let suiteName = "PocketFinancerTests.PrimaryCurrency.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let unconfirmedDefault = PrimaryCurrencySettings.snapshot(in: defaults)
        XCTAssertEqual(unconfirmedDefault.currentCode, "INR")
        XCTAssertNil(unconfirmedDefault.confirmedCode)
        XCTAssertFalse(unconfirmedDefault.isConfirmed)
        XCTAssertEqual(unconfirmedDefault.enabledProfiles, ["core-en", "india"])

        let storedButUnconfirmed = PrimaryCurrencySettings.snapshot(storedCode: "USD", isConfirmed: false)
        XCTAssertEqual(storedButUnconfirmed.currentCode, "USD")
        XCTAssertNil(storedButUnconfirmed.confirmedCode)
        XCTAssertFalse(storedButUnconfirmed.isConfirmed)

        let unsupportedConfirmed = PrimaryCurrencySettings.snapshot(storedCode: "ZZZ", isConfirmed: true)
        XCTAssertEqual(unsupportedConfirmed.currentCode, "INR")
        XCTAssertNil(unsupportedConfirmed.confirmedCode)
        XCTAssertFalse(unsupportedConfirmed.isConfirmed)

        PrimaryCurrencySettings.confirm("eur", in: defaults)
        let confirmed = PrimaryCurrencySettings.snapshot(in: defaults)
        XCTAssertEqual(confirmed.currentCode, "EUR")
        XCTAssertEqual(confirmed.confirmedCode, "EUR")
        XCTAssertTrue(confirmed.isConfirmed)
        XCTAssertEqual(confirmed.enabledProfiles, ["core-en"])

        PrimaryCurrencySettings.reset(in: defaults)
        XCTAssertNil(PrimaryCurrencySettings.snapshot(in: defaults).confirmedCode)

        XCTAssertFalse(
            PendingAlertDrainPolicy.mayDrain(
                completedOnboarding: true,
                scenePhase: .active,
                confirmedPrimaryCurrency: nil
            )
        )
        XCTAssertFalse(
            PendingAlertDrainPolicy.mayDrain(
                completedOnboarding: true,
                scenePhase: .active,
                confirmedPrimaryCurrency: "ZZZ"
            )
        )
        XCTAssertTrue(
            PendingAlertDrainPolicy.mayDrain(
                completedOnboarding: true,
                scenePhase: .active,
                confirmedPrimaryCurrency: "inr"
            )
        )
        XCTAssertFalse(
            PendingAlertDrainPolicy.mayDrain(
                completedOnboarding: false,
                scenePhase: .active,
                confirmedPrimaryCurrency: "INR"
            )
        )
        for phase in [ScenePhase.inactive, .background] {
            XCTAssertFalse(
                PendingAlertDrainPolicy.mayDrain(
                    completedOnboarding: true,
                    scenePhase: phase,
                    confirmedPrimaryCurrency: "USD"
                )
            )
        }

        let beforeConfirm = PendingAlertDrainPolicy.trigger(
            completedOnboarding: true,
            scenePhase: .active,
            confirmedPrimaryCurrency: nil
        )
        let afterConfirmINR = PendingAlertDrainPolicy.trigger(
            completedOnboarding: true,
            scenePhase: .active,
            confirmedPrimaryCurrency: "INR"
        )
        let afterConfirmUSD = PendingAlertDrainPolicy.trigger(
            completedOnboarding: true,
            scenePhase: .active,
            confirmedPrimaryCurrency: "USD"
        )
        XCTAssertFalse(beforeConfirm.mayDrain)
        XCTAssertTrue(afterConfirmINR.mayDrain)
        XCTAssertNotEqual(beforeConfirm, afterConfirmINR)
        XCTAssertNotEqual(afterConfirmINR, afterConfirmUSD)
    }

    @MainActor
    func testCurrencySymbolMappingCoversSupportedCurrenciesAndNeutralFallback() {
        XCTAssertEqual(CurrencyFormatter.symbolName(for: "INR"), "indianrupeesign.circle")
        XCTAssertEqual(CurrencyFormatter.symbolName(for: "INR", filled: true), "indianrupeesign.circle.fill")
        for dollarCode in ["USD", "AUD", "CAD", "SGD", " usd "] {
            XCTAssertEqual(CurrencyFormatter.symbolName(for: dollarCode), "dollarsign.circle")
            XCTAssertEqual(CurrencyFormatter.symbolName(for: dollarCode, filled: true), "dollarsign.circle.fill")
        }
        XCTAssertEqual(CurrencyFormatter.symbolName(for: "EUR"), "eurosign.circle")
        XCTAssertEqual(CurrencyFormatter.symbolName(for: "EUR", filled: true), "eurosign.circle.fill")
        XCTAssertEqual(CurrencyFormatter.symbolName(for: "GBP"), "sterlingsign.circle")
        XCTAssertEqual(CurrencyFormatter.symbolName(for: "JPY"), "yensign.circle")
        XCTAssertEqual(CurrencyFormatter.symbolName(for: "CHF"), "francsign.circle")
        XCTAssertEqual(CurrencyFormatter.symbolName(for: "AED"), "banknote")
        XCTAssertEqual(CurrencyFormatter.symbolName(for: "AED", filled: true), "banknote.fill")
        XCTAssertEqual(CurrencyFormatter.symbolName(for: "ZZZ"), "banknote")
        XCTAssertEqual(CurrencyFormatter.symbolName(for: "", filled: true), "banknote.fill")
    }

    @MainActor
    func testMonthlyCashFlowSummaryKeepsCurrenciesSeparateAndPrioritizesPrimaryCurrency() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let augustMid = try XCTUnwrap(
            calendar.date(from: DateComponents(year: 2026, month: 8, day: 15, hour: 12))
        )
        let julyLate = try XCTUnwrap(
            calendar.date(from: DateComponents(year: 2026, month: 7, day: 31, hour: 23))
        )
        let septemberEarly = try XCTUnwrap(
            calendar.date(from: DateComponents(year: 2026, month: 9, day: 1, hour: 0))
        )

        let entries = [
            MonthlyCashFlowEntry(
                amountMinorUnits: 100_000,
                currencyCode: "INR",
                direction: .credit,
                occurredAt: augustMid
            ),
            MonthlyCashFlowEntry(
                amountMinorUnits: 25_000,
                currencyCode: "inr",
                direction: .debit,
                occurredAt: augustMid
            ),
            MonthlyCashFlowEntry(
                amountMinorUnits: 10_000,
                currencyCode: "USD",
                direction: .credit,
                occurredAt: augustMid
            ),
            MonthlyCashFlowEntry(
                amountMinorUnits: 1_500,
                currencyCode: "USD",
                direction: .debit,
                occurredAt: augustMid
            ),
            MonthlyCashFlowEntry(
                amountMinorUnits: 2_500,
                currencyCode: " usd ",
                direction: .debit,
                occurredAt: augustMid
            ),
            MonthlyCashFlowEntry(
                amountMinorUnits: 5_000,
                currencyCode: "EUR",
                direction: .debit,
                occurredAt: augustMid
            ),
            MonthlyCashFlowEntry(
                amountMinorUnits: 999_999,
                currencyCode: "INR",
                direction: .debit,
                occurredAt: julyLate
            ),
            MonthlyCashFlowEntry(
                amountMinorUnits: 888_888,
                currencyCode: "USD",
                direction: .credit,
                occurredAt: septemberEarly
            ),
        ]

        let summary = MonthlyCashFlowSummary.build(
            entries: entries,
            primaryCurrencyCode: "INR",
            referenceDate: augustMid,
            calendar: calendar
        )

        XCTAssertEqual(summary.primaryCurrencyCode, "INR")
        XCTAssertTrue(summary.isMultiCurrency)
        XCTAssertFalse(summary.showsFallbackCurrencyAsHero)
        XCTAssertEqual(
            summary.hero,
            MonthlyCurrencySummary(
                currencyCode: "INR",
                creditsMinorUnits: 100_000,
                debitsMinorUnits: 25_000,
                transactionCount: 2
            )
        )
        XCTAssertEqual(summary.hero.netMinorUnits, 75_000)
        XCTAssertEqual(
            summary.secondaryCurrencies,
            [
                MonthlyCurrencySummary(
                    currencyCode: "USD",
                    creditsMinorUnits: 10_000,
                    debitsMinorUnits: 4_000,
                    transactionCount: 3
                ),
                MonthlyCurrencySummary(
                    currencyCode: "EUR",
                    creditsMinorUnits: 0,
                    debitsMinorUnits: 5_000,
                    transactionCount: 1
                ),
            ]
        )
        XCTAssertEqual(summary.secondaryCurrencies.first?.netMinorUnits, 6_000)
        XCTAssertEqual(summary.secondaryCurrencies.last?.netMinorUnits, -5_000)
    }

    @MainActor
    func testMonthlyCashFlowSummaryFallsBackToDominantCurrencyAndHandlesEmptyMonth() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let augustMid = try XCTUnwrap(
            calendar.date(from: DateComponents(year: 2026, month: 8, day: 15, hour: 12))
        )

        let empty = MonthlyCashFlowSummary.build(
            entries: [],
            primaryCurrencyCode: "USD",
            referenceDate: augustMid,
            calendar: calendar
        )
        XCTAssertEqual(empty.hero.currencyCode, "USD")
        XCTAssertEqual(empty.hero.netMinorUnits, 0)
        XCTAssertEqual(empty.hero.transactionCount, 0)
        XCTAssertTrue(empty.secondaryCurrencies.isEmpty)
        XCTAssertFalse(empty.isMultiCurrency)
        XCTAssertFalse(empty.showsFallbackCurrencyAsHero)

        let dominant = MonthlyCashFlowSummary.build(
            entries: [
                MonthlyCashFlowEntry(
                    amountMinorUnits: 5_000,
                    currencyCode: "USD",
                    direction: .debit,
                    occurredAt: augustMid
                ),
                MonthlyCashFlowEntry(
                    amountMinorUnits: 2_000,
                    currencyCode: "USD",
                    direction: .debit,
                    occurredAt: augustMid
                ),
                MonthlyCashFlowEntry(
                    amountMinorUnits: 1_250,
                    currencyCode: "JPY",
                    direction: .debit,
                    occurredAt: augustMid
                ),
            ],
            primaryCurrencyCode: "INR",
            referenceDate: augustMid,
            calendar: calendar
        )
        XCTAssertEqual(dominant.hero.currencyCode, "USD")
        XCTAssertEqual(dominant.hero.debitsMinorUnits, 7_000)
        XCTAssertEqual(dominant.secondaryCurrencies.map(\.currencyCode), ["JPY"])
        XCTAssertTrue(dominant.showsFallbackCurrencyAsHero)
        XCTAssertTrue(dominant.isMultiCurrency)

        let tieBreak = MonthlyCashFlowSummary.build(
            entries: [
                MonthlyCashFlowEntry(
                    amountMinorUnits: 5_000,
                    currencyCode: "USD",
                    direction: .debit,
                    occurredAt: augustMid
                ),
                MonthlyCashFlowEntry(
                    amountMinorUnits: 5_000,
                    currencyCode: "EUR",
                    direction: .debit,
                    occurredAt: augustMid
                ),
            ],
            primaryCurrencyCode: "INR",
            referenceDate: augustMid,
            calendar: calendar
        )
        XCTAssertEqual(tieBreak.hero.currencyCode, "EUR")
        XCTAssertEqual(tieBreak.secondaryCurrencies.map(\.currencyCode), ["USD"])
    }

    @MainActor
    func testSettingsRetryStatusMessageReportsZeroAndPerOutcomeCountsHonestly() {
        let initial = StorageDiagnostic(pending: 1, needsReview: 2, imported: 3, rejected: 1, duplicates: 0)

        let noneRetried = SettingsView.retryStatusMessage(retried: 0, before: initial, after: initial)
        XCTAssertTrue(noneRetried.contains("No saved alerts could be retried"))

        let singleImported = SettingsView.retryStatusMessage(
            retried: 1,
            before: StorageDiagnostic(pending: 0, needsReview: 1, imported: 0, rejected: 0, duplicates: 0),
            after: StorageDiagnostic(pending: 0, needsReview: 0, imported: 1, rejected: 0, duplicates: 0)
        )
        XCTAssertEqual(singleImported, "Retried 1 saved alert locally. 1 imported.")

        let mixedOutcomes = SettingsView.retryStatusMessage(
            retried: 3,
            before: initial,
            after: StorageDiagnostic(pending: 0, needsReview: 1, imported: 4, rejected: 2, duplicates: 0)
        )
        XCTAssertEqual(
            mixedOutcomes,
            "Retried 3 saved alerts locally. 1 imported. 1 cleared as non-transaction. 1 still needs review."
        )

        let stillInReview = SettingsView.retryStatusMessage(
            retried: 2,
            before: StorageDiagnostic(pending: 0, needsReview: 2, imported: 0, rejected: 0, duplicates: 0),
            after: StorageDiagnostic(pending: 0, needsReview: 2, imported: 0, rejected: 0, duplicates: 0)
        )
        XCTAssertEqual(stillInReview, "Retried 2 saved alerts locally. 2 still need review.")
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
