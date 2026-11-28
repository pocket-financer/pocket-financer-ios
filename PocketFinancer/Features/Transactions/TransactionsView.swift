import Foundation
import SwiftData
import SwiftUI

struct TransactionsView: View {
    @Query(sort: \Transaction.occurredAt, order: .reverse) private var transactions: [Transaction]
    @Query(sort: \InboxAlert.createdAt, order: .reverse) private var alerts: [InboxAlert]
    @Query(sort: \SmsReviewCase.updatedAt, order: .reverse) private var reviewCases: [SmsReviewCase]
    @Query(sort: \SmsReconstructedResult.createdAt, order: .reverse)
    private var reconstructedResults: [SmsReconstructedResult]
    @State private var searchText = ""
    @State private var showingManualImport = false

    private var reviewTransactions: [Transaction] {
        transactions.filter { transaction in
            transaction.reviewState == .needsReview && matchesSearch(transaction)
        }
    }

    private var confirmedTransactions: [Transaction] {
        transactions.filter { transaction in
            transaction.reviewState == .confirmed && matchesSearch(transaction)
        }
    }

    private var reviewAlerts: [InboxAlert] {
        let representedTransactionIDs = Set(
            transactions
                .filter { $0.reviewState == .needsReview }
                .map(\.id)
        )
        return alerts.filter { alert in
            let hasRepresentedTransaction = alert.transactionID.map(representedTransactionIDs.contains) ?? false
            guard alert.status == .needsReview && !hasRepresentedTransaction else { return false }
            guard !searchText.isEmpty else { return true }
            let preview = reviewPreview(for: alert)
            return alert.sender.localizedCaseInsensitiveContains(searchText)
                || (preview.counterparty?.localizedCaseInsensitiveContains(searchText) ?? false)
                || (preview.accountReference?.localizedCaseInsensitiveContains(searchText) ?? false)
        }
    }

    private var processingAlerts: [InboxAlert] {
        guard searchText.isEmpty else { return [] }
        return alerts.filter { $0.status == .pending || $0.status == .processing }
    }

    private var hasVisibleContent: Bool {
        !reviewTransactions.isEmpty
            || !reviewAlerts.isEmpty
            || !processingAlerts.isEmpty
            || !confirmedTransactions.isEmpty
    }

    var body: some View {
        NavigationStack {
            Group {
                if !hasVisibleContent {
                    EmptyStateView(
                        systemImage: "text.document",
                        title: searchText.isEmpty ? "No transactions" : "No matches",
                        detail: searchText.isEmpty
                            ? "Use the plus button to try a synthetic transaction alert."
                            : "Try a different merchant or account."
                    )
                } else {
                    List {
                        if !processingAlerts.isEmpty {
                            Section("Processing") {
                                ForEach(processingAlerts) { alert in
                                    NavigationLink {
                                        AlertProcessingDetailView(alert: alert)
                                    } label: {
                                        AlertQueueRow(alert: alert)
                                    }
                                }
                            }
                        }

                        if !reviewTransactions.isEmpty || !reviewAlerts.isEmpty {
                            Section("Needs Review") {
                                ForEach(reviewTransactions) { transaction in
                                    NavigationLink {
                                        TransactionDetailView(transaction: transaction)
                                    } label: {
                                        ReviewTransactionRow(transaction: transaction)
                                    }
                                }

                                ForEach(reviewAlerts) { alert in
                                    let reviewCase = activeReviewCase(for: alert)
                                    let preview = reviewPreview(for: alert, reviewCase: reviewCase)
                                    NavigationLink {
                                        if let reviewCase {
                                            ReviewCorrectionView(
                                                reviewCase: reviewCase,
                                                sourceAlert: alert
                                            )
                                        } else {
                                            AlertProcessingDetailView(alert: alert)
                                        }
                                    } label: {
                                        NeedsReviewAlertRow(alert: alert, preview: preview)
                                    }
                                    .accessibilityIdentifier(
                                        "needs-review-alert-\(alert.id.uuidString.lowercased())"
                                    )
                                }
                            }
                        }

                        if !confirmedTransactions.isEmpty {
                            Section("Transactions") {
                                ForEach(confirmedTransactions) { transaction in
                                    NavigationLink {
                                        TransactionDetailView(transaction: transaction)
                                    } label: {
                                        TransactionRow(transaction: transaction)
                                    }
                                }
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("Transactions")
            .searchable(text: $searchText, prompt: "Merchant or account")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingManualImport = true
                    } label: {
                        Label("Import Alert", systemImage: "plus")
                    }
                    .accessibilityIdentifier("import-alert-button")
                }
            }
            .sheet(isPresented: $showingManualImport) {
                ManualAlertImportView()
            }
        }
    }

    private func matchesSearch(_ transaction: Transaction) -> Bool {
        searchText.isEmpty
            || transaction.merchant.localizedCaseInsensitiveContains(searchText)
            || (transaction.accountLabel?.localizedCaseInsensitiveContains(searchText) ?? false)
    }

    private func activeReviewCase(for alert: InboxAlert) -> SmsReviewCase? {
        let matching = reviewCases.filter { $0.sourceAlertID == alert.id }
        if let openOrDraft = matching.first(where: { $0.state == .open || $0.state == .draft }) {
            return openOrDraft
        }
        return matching.first(where: { $0.state == .waitingRetry })
    }

    private func reviewPreview(
        for alert: InboxAlert,
        reviewCase: SmsReviewCase? = nil
    ) -> NeedsReviewPreview {
        let resolvedCase = reviewCase ?? activeReviewCase(for: alert)
        let resultJSON = resolvedCase.flatMap { review in
            reconstructedResults.first { $0.operationID == review.currentOperationID }?.semanticResultJSON
        }
        let reasonCodes =
            resolvedCase?.reasonCodesRawValue
            .split(separator: "\n")
            .map(String.init) ?? []
        return NeedsReviewPreview.build(
            alert: alert,
            resultJSON: resultJSON,
            reasonCodes: reasonCodes
        )
    }
}

private struct NeedsReviewPreview {
    let headline: String
    let subtitle: String
    let amountText: String?
    let direction: String?
    let counterparty: String?
    let accountReference: String?
    let reasonTitle: String
    let isDuplicateWarning: Bool

    static func build(
        alert: InboxAlert,
        resultJSON: String?,
        reasonCodes: [String]
    ) -> NeedsReviewPreview {
        let proposal = SmsReviewProjection.parse(resultJSON: resultJSON, source: alert.rawBody)
        let retained = SmsReviewProjection.parseRetainedEvidence(
            resultJSON: resultJSON,
            analysisJSON: nil,
            operationConfigurationJSON: nil,
            source: alert.rawBody,
            fallbackPrimaryCurrency: PrimaryCurrencySettings.currentCode,
            fallbackReceiptTimestamp: alert.receivedAt,
            fallbackReceiptProvenance: "platform_received"
        )

        let amountMinorUnits = proposal?.amountMinorUnits ?? retained.slmFields[.amount]?.normalizedAmount?.minorUnits
        let currency = proposal?.currency ?? retained.slmFields[.amount]?.normalizedAmount?.currency
        let amountText: String? =
            if let amountMinorUnits, let currency {
                CurrencyFormatter.string(minorUnits: amountMinorUnits, currencyCode: currency)
            } else {
                nil
            }

        let direction = proposal?.direction ?? retained.slmFields[.direction]?.normalizedDirection?.rawValue
        let counterparty = proposal?.counterparty ?? retained.slmFields[.counterparty]?.normalizedCounterparty
        let accountReference = proposal?.accountReference ?? retained.slmFields[.account]?.normalizedAccount
        let trimmedSender = alert.sender.trimmingCharacters(in: .whitespacesAndNewlines)

        let headline: String
        if let counterparty, !counterparty.isEmpty {
            headline = counterparty
        } else if !trimmedSender.isEmpty {
            headline = trimmedSender
        } else {
            headline = "Saved alert"
        }

        let timestamp = alert.receivedAt.formatted(date: .abbreviated, time: .shortened)
        let subtitle: String
        if let counterparty, !counterparty.isEmpty, !trimmedSender.isEmpty {
            subtitle = "\(trimmedSender) · \(timestamp)"
        } else if let accountReference, !accountReference.isEmpty {
            let formattedAccount =
                accountReference.contains("@")
                ? accountReference
                : "••\(accountReference.suffix(4))"
            subtitle = "\(formattedAccount) · \(timestamp)"
        } else {
            subtitle = timestamp
        }

        let primaryCode = reasonCodes.first ?? alert.lastErrorCode
        let isDuplicateWarning =
            proposal?.duplicateStatus == "possible_duplicate"
            || reasonCodes.contains("duplicate_possible")
            || alert.lastErrorCode == "duplicate_possible"
        let reasonTitle = conciseReason(for: primaryCode)

        return NeedsReviewPreview(
            headline: headline,
            subtitle: subtitle,
            amountText: amountText,
            direction: direction,
            counterparty: counterparty,
            accountReference: accountReference,
            reasonTitle: reasonTitle,
            isDuplicateWarning: isDuplicateWarning
        )
    }

    private static func conciseReason(for code: String?) -> String {
        guard let code, !code.isEmpty else {
            return "Tap to review saved alert"
        }
        switch code {
        case "account_resolution_unresolved":
            return "Confirm account to save"
        case "account_resolution_ambiguous":
            return "Choose matching account"
        case "duplicate_possible":
            return "Possible duplicate within 5 minutes"
        case "duplicate_already_persisted":
            return "Already saved"
        default:
            return AlertProcessingDiagnostics.presentation(for: code).title
        }
    }
}

private struct NeedsReviewAlertRow: View {
    let alert: InboxAlert
    let preview: NeedsReviewPreview

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(
                systemName: preview.isDuplicateWarning
                    ? "doc.on.doc.fill"
                    : "exclamationmark.bubble.fill"
            )
            .foregroundStyle(.orange)
            .frame(width: 24)
            .padding(.top, 2)

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(preview.headline)
                        .font(.headline)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if let amountText = preview.amountText {
                        Text(amountText)
                            .font(.headline.monospacedDigit())
                            .foregroundStyle(preview.direction == "credit" ? Color.green : Color.primary)
                    } else {
                        Text("Review")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(.orange.opacity(0.14), in: Capsule())
                    }
                }

                Text(preview.subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Text(preview.reasonTitle)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary)
    }

    private var accessibilitySummary: String {
        var parts = ["Needs review", preview.headline]
        if let amountText = preview.amountText {
            parts.append(amountText)
        }
        parts.append(preview.reasonTitle)
        return parts.joined(separator: ", ")
    }
}

private struct ReviewTransactionRow: View {
    let transaction: Transaction

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(transaction.merchant)
                        .font(.headline)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text(
                        CurrencyFormatter.string(
                            minorUnits: transaction.amountMinorUnits,
                            currencyCode: transaction.currencyCode
                        )
                    )
                    .font(.headline.monospacedDigit())
                }

                Text(transaction.accountLabel ?? "Unknown account")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Text(transaction.ownerReviewReason)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "Review required, \(transaction.merchant), "
                + "\(CurrencyFormatter.string(minorUnits: transaction.amountMinorUnits, currencyCode: transaction.currencyCode)), "
                + "account \(transaction.accountLabel ?? "unknown"), \(transaction.ownerReviewReason)"
        )
        .accessibilityIdentifier("review-required-transaction-\(transaction.id.uuidString.lowercased())")
    }
}

extension Transaction {
    var ownerReviewReason: String {
        let merchantNeedsReview =
            merchant.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || merchant.localizedCaseInsensitiveCompare("Unknown Merchant") == .orderedSame
        let dateNeedsReview = dateEvidenceText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true

        return switch (merchantNeedsReview, dateNeedsReview) {
        case (true, true):
            "Model merchant and date outputs were empty; receipt time was used"
        case (true, false):
            "Model merchant or counterparty output was empty"
        case (false, true):
            "Model date output was empty; the SMS receipt time was used"
        case (false, false):
            "Confirm the extracted details before completing review"
        }
    }
}

private struct AlertQueueRow: View {
    let alert: InboxAlert

    private var title: String {
        switch alert.status {
        case .pending:
            "Saved for local retry"
        case .processing:
            "Processing on this iPhone"
        case .needsReview:
            "Needs review"
        default:
            "Saved alert"
        }
    }

    private var detail: String {
        if let code = alert.lastErrorCode {
            return AlertProcessingDiagnostics.presentation(for: code).title
        }
        return "Evidence is retained locally"
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: alert.status == .needsReview ? "exclamationmark.bubble.fill" : "clock.fill")
                .foregroundStyle(alert.status == .needsReview ? .orange : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }
}
