import Foundation
import SwiftData
import SwiftUI

struct MonthlyCashFlowEntry: Equatable, Sendable {
    let amountMinorUnits: Int64
    let currencyCode: String
    let direction: TransactionDirection
    let occurredAt: Date
}

struct MonthlyCurrencySummary: Equatable, Identifiable, Sendable {
    let currencyCode: String
    let creditsMinorUnits: Decimal
    let debitsMinorUnits: Decimal
    let transactionCount: Int

    nonisolated var id: String { currencyCode }
    nonisolated var netMinorUnits: Decimal { creditsMinorUnits - debitsMinorUnits }
}

struct MonthlyCashFlowSummary: Equatable, Sendable {
    let hero: MonthlyCurrencySummary
    let secondaryCurrencies: [MonthlyCurrencySummary]
    let allCurrencies: [MonthlyCurrencySummary]
    let primaryCurrencyCode: String

    nonisolated var isMultiCurrency: Bool { allCurrencies.count > 1 }
    nonisolated var showsFallbackCurrencyAsHero: Bool {
        hero.currencyCode != primaryCurrencyCode && hero.transactionCount > 0
    }

    static func build(
        transactions: [Transaction],
        primaryCurrencyCode: String,
        referenceDate: Date = .now,
        calendar: Calendar = .current
    ) -> MonthlyCashFlowSummary {
        build(
            entries: transactions.map {
                MonthlyCashFlowEntry(
                    amountMinorUnits: $0.amountMinorUnits,
                    currencyCode: $0.currencyCode,
                    direction: $0.direction,
                    occurredAt: $0.occurredAt
                )
            },
            primaryCurrencyCode: primaryCurrencyCode,
            referenceDate: referenceDate,
            calendar: calendar
        )
    }

    nonisolated static func build(
        entries: [MonthlyCashFlowEntry],
        primaryCurrencyCode: String,
        referenceDate: Date = .now,
        calendar: Calendar = .current
    ) -> MonthlyCashFlowSummary {
        let normalizedPrimary =
            PrimaryCurrencySettings.normalizedSupportedCode(primaryCurrencyCode)
            ?? normalizedCurrencyCode(primaryCurrencyCode, fallback: PrimaryCurrencySettings.defaultCode)

        let monthInterval = calendar.dateInterval(of: .month, for: referenceDate)
        let monthEntries = entries.filter { entry in
            guard let monthInterval else { return true }
            return entry.occurredAt >= monthInterval.start && entry.occurredAt < monthInterval.end
        }

        var buckets: [String: (credits: Decimal, debits: Decimal, count: Int)] = [:]
        for entry in monthEntries {
            let code = normalizedCurrencyCode(entry.currencyCode, fallback: normalizedPrimary)
            var bucket = buckets[code] ?? (credits: .zero, debits: .zero, count: 0)
            switch entry.direction {
            case .credit:
                bucket.credits += Decimal(entry.amountMinorUnits)
            case .debit:
                bucket.debits += Decimal(entry.amountMinorUnits)
            }
            bucket.count += 1
            buckets[code] = bucket
        }

        if buckets.isEmpty {
            let emptyHero = MonthlyCurrencySummary(
                currencyCode: normalizedPrimary,
                creditsMinorUnits: .zero,
                debitsMinorUnits: .zero,
                transactionCount: 0
            )
            return MonthlyCashFlowSummary(
                hero: emptyHero,
                secondaryCurrencies: [],
                allCurrencies: [emptyHero],
                primaryCurrencyCode: normalizedPrimary
            )
        }

        let allSummaries = buckets.map { code, bucket in
            MonthlyCurrencySummary(
                currencyCode: code,
                creditsMinorUnits: bucket.credits,
                debitsMinorUnits: bucket.debits,
                transactionCount: bucket.count
            )
        }
        let sortedByActivity = allSummaries.sorted { lhs, rhs in
            if lhs.transactionCount != rhs.transactionCount {
                return lhs.transactionCount > rhs.transactionCount
            }
            return lhs.currencyCode < rhs.currencyCode
        }

        let hero: MonthlyCurrencySummary
        let secondaryCurrencies: [MonthlyCurrencySummary]
        if let primarySummary = allSummaries.first(where: { $0.currencyCode == normalizedPrimary }) {
            hero = primarySummary
            secondaryCurrencies = sortedByActivity.filter { $0.currencyCode != normalizedPrimary }
        } else {
            hero = sortedByActivity[0]
            secondaryCurrencies = Array(sortedByActivity.dropFirst())
        }

        return MonthlyCashFlowSummary(
            hero: hero,
            secondaryCurrencies: secondaryCurrencies,
            allCurrencies: [hero] + secondaryCurrencies,
            primaryCurrencyCode: normalizedPrimary
        )
    }

    private nonisolated static func normalizedCurrencyCode(_ rawCode: String, fallback: String) -> String {
        let trimmed = rawCode.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return trimmed.isEmpty ? fallback : trimmed
    }
}

struct HomeView: View {
    @PrimaryCurrencyState private var primaryCurrency
    @Query(sort: \Transaction.occurredAt, order: .reverse) private var transactions: [Transaction]
    @Query private var alerts: [InboxAlert]
    @State private var selectedPrimaryCurrency = PrimaryCurrencySettings.currentCode

    private var monthlySummary: MonthlyCashFlowSummary {
        MonthlyCashFlowSummary.build(
            transactions: transactions,
            primaryCurrencyCode: primaryCurrency.currentCode
        )
    }

    private var waitingAlertCount: Int {
        alerts.count { $0.status == .pending || $0.status == .processing }
    }

    private var pendingCount: Int {
        alerts.count { $0.status == .pending || $0.status == .processing || $0.status == .needsReview }
    }

    var body: some View {
        let summary = monthlySummary

        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 24) {
                    if !primaryCurrency.isConfirmed {
                        PrimaryCurrencyConfirmationBanner(
                            selectedCurrency: $selectedPrimaryCurrency,
                            waitingAlertCount: waitingAlertCount
                        ) {
                            withAnimation {
                                PrimaryCurrencySettings.confirm(selectedPrimaryCurrency)
                            }
                        }
                    }

                    MonthlyHeroCard(summary: summary)

                    if !summary.secondaryCurrencies.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Other currencies this month")
                                .font(.headline)
                                .foregroundStyle(.secondary)

                            ForEach(summary.secondaryCurrencies) { currencySummary in
                                CurrencySummaryRow(summary: currencySummary)
                            }
                        }
                        .accessibilityIdentifier("monthly-other-currencies")
                    }

                    if pendingCount > 0 {
                        NavigationLink {
                            TransactionsView()
                        } label: {
                            Label(
                                "\(pendingCount) alert\(pendingCount == 1 ? "" : "s") need attention",
                                systemImage: "tray.full.fill"
                            )
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.glass)
                    }

                    CurrentModelStatusView()

                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("Recent")
                                .font(.title2.bold())
                            Spacer()
                        }

                        if transactions.isEmpty {
                            EmptyStateView(
                                systemImage: CurrencyFormatter.symbolName(for: primaryCurrency.currentCode),
                                title: "No transactions yet",
                                detail: "Import a synthetic alert manually or connect the Shortcuts action."
                            )
                            .frame(minHeight: 240)
                        } else {
                            ForEach(transactions.prefix(5)) { transaction in
                                NavigationLink {
                                    TransactionDetailView(transaction: transaction)
                                } label: {
                                    TransactionRow(transaction: transaction)
                                }
                                .buttonStyle(.plain)
                                Divider()
                            }
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("Pocket Financer")
            .onAppear {
                selectedPrimaryCurrency = primaryCurrency.currentCode
            }
            .onChange(of: primaryCurrency.currentCode) { _, newValue in
                selectedPrimaryCurrency = newValue
            }
        }
    }
}

private struct PrimaryCurrencyConfirmationBanner: View {
    @Binding var selectedCurrency: String
    let waitingAlertCount: Int
    let onConfirm: () -> Void

    private var explanation: String {
        if waitingAlertCount > 0 {
            let plural = waitingAlertCount == 1 ? "" : "s"
            return "Alert processing is paused (\(waitingAlertCount) saved alert\(plural) waiting). "
                + "Confirm your fallback currency to resume local processing right away."
        }
        return "Alert processing is paused until you confirm your fallback currency. "
            + "Explicit currency markers in messages always take priority."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: CurrencyFormatter.symbolName(for: selectedCurrency, filled: true))
                    .font(.title2)
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Confirm your primary currency")
                        .font(.headline)
                    Text(explanation)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            LabeledContent("Primary currency") {
                Picker("Primary currency", selection: $selectedCurrency) {
                    ForEach(PrimaryCurrencySettings.supportedCodes, id: \.self) { code in
                        Text(code).tag(code)
                    }
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("home-primary-currency-picker")
            }

            Button(action: onConfirm) {
                Label("Confirm \(selectedCurrency)", systemImage: "checkmark.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("home-confirm-primary-currency")
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular.tint(.orange.opacity(0.14)), in: .rect(cornerRadius: 24))
        .accessibilityIdentifier("primary-currency-confirmation-banner")
    }
}

private struct MonthlyHeroCard: View {
    let summary: MonthlyCashFlowSummary

    private var subtitle: String {
        if summary.showsFallbackCurrencyAsHero {
            return "Net cash flow in \(summary.hero.currencyCode) · "
                + "No \(summary.primaryCurrencyCode) activity this month"
        }
        if summary.isMultiCurrency {
            return "Net cash flow in \(summary.hero.currencyCode) · Kept separate by currency"
        }
        return "Net cash flow"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("This month")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Label(
                    summary.hero.currencyCode,
                    systemImage: CurrencyFormatter.symbolName(for: summary.hero.currencyCode, filled: true)
                )
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(.quaternary, in: Capsule())
                .accessibilityIdentifier("monthly-summary-currency")
            }

            Text(
                CurrencyFormatter.string(
                    minorUnits: summary.hero.netMinorUnits,
                    currencyCode: summary.hero.currencyCode
                )
            )
            .font(.system(.largeTitle, design: .rounded, weight: .bold))
            .minimumScaleFactor(0.7)

            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            HStack(spacing: 20) {
                SummaryValue(
                    title: "In",
                    value: summary.hero.creditsMinorUnits,
                    currencyCode: summary.hero.currencyCode,
                    color: .green,
                    symbol: "arrow.down.left"
                )
                Divider().frame(height: 42)
                SummaryValue(
                    title: "Out",
                    value: summary.hero.debitsMinorUnits,
                    currencyCode: summary.hero.currencyCode,
                    color: .orange,
                    symbol: "arrow.up.right"
                )
            }
            .padding(.top, 12)
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular.tint(.accentColor.opacity(0.10)), in: .rect(cornerRadius: 28))
        .accessibilityIdentifier("monthly-summary")
    }
}

private struct CurrencySummaryRow: View {
    let summary: MonthlyCurrencySummary

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Label(
                    summary.currencyCode,
                    systemImage: CurrencyFormatter.symbolName(for: summary.currencyCode, filled: true)
                )
                .font(.headline)

                Text("\(summary.transactionCount) transaction\(summary.transactionCount == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                Text(
                    CurrencyFormatter.string(
                        minorUnits: summary.netMinorUnits,
                        currencyCode: summary.currencyCode
                    )
                )
                .font(.headline.monospacedDigit())
            }

            HStack(spacing: 16) {
                Label(
                    "In \(CurrencyFormatter.string(minorUnits: summary.creditsMinorUnits, currencyCode: summary.currencyCode))",
                    systemImage: "arrow.down.left"
                )
                .font(.caption.monospacedDigit())
                .foregroundStyle(.green)

                Spacer()

                Label(
                    "Out \(CurrencyFormatter.string(minorUnits: summary.debitsMinorUnits, currencyCode: summary.currencyCode))",
                    systemImage: "arrow.up.right"
                )
                .font(.caption.monospacedDigit())
                .foregroundStyle(.orange)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("monthly-currency-\(summary.currencyCode)")
    }
}

private struct SummaryValue: View {
    let title: String
    let value: Decimal
    let currencyCode: String
    let color: Color
    let symbol: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(title, systemImage: symbol)
                .font(.caption.weight(.semibold))
                .foregroundStyle(color)
            Text(CurrencyFormatter.string(minorUnits: value, currencyCode: currencyCode))
                .font(.headline.monospacedDigit())
                .foregroundStyle(.primary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
