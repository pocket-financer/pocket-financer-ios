import SwiftData
import SwiftUI

struct TransactionsView: View {
    @Query(sort: \Transaction.occurredAt, order: .reverse) private var transactions: [Transaction]
    @Query(sort: \InboxAlert.createdAt, order: .reverse) private var alerts: [InboxAlert]
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
        guard searchText.isEmpty else { return [] }
        let representedTransactionIDs = Set(
            transactions
                .filter { $0.reviewState == .needsReview }
                .map(\.id)
        )
        return alerts.filter { alert in
            let hasRepresentedTransaction = alert.transactionID.map(representedTransactionIDs.contains) ?? false
            return alert.status == .needsReview
                && !hasRepresentedTransaction
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
                                    NavigationLink {
                                        AlertProcessingDetailView(alert: alert)
                                    } label: {
                                        AlertQueueRow(alert: alert)
                                    }
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
            "Review required, \(transaction.merchant), \(CurrencyFormatter.string(minorUnits: transaction.amountMinorUnits, currencyCode: transaction.currencyCode)), account \(transaction.accountLabel ?? "unknown"), \(transaction.ownerReviewReason)"
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
        switch alert.lastErrorCode {
        case "model_appleIntelligenceNotEnabled":
            "Enable Apple Intelligence, then retry"
        case "model_modelNotReady":
            "Apple's model is still preparing"
        case "model_assets_unavailable":
            "Apple's local model assets are not ready"
        case "model_deviceNotEligible":
            "This device cannot run the local model"
        case "model_timed_out":
            "The local model timed out"
        case "model_cancelled":
            "Local processing was interrupted"
        case "model_rate_limited", "model_concurrent_requests":
            "The local model is temporarily busy"
        case "model_unsupported_language":
            "The alert language is not supported locally"
        case "model_guardrail_violation", "model_refused":
            "Apple's local model declined this alert"
        case "model_unsupported_guide", "model_decoding_failed":
            "The installed model could not use the extraction schema"
        case "model_context_window_exceeded":
            "The alert exceeded the local model context"
        case "model_generation_failed":
            "No safe extraction was produced"
        case EvidenceValidationIssue.modelRejected.rawValue:
            "The model was uncertain; evidence was retained"
        default:
            "Evidence is retained locally"
        }
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
