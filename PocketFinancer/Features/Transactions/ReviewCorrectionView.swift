import Foundation
import SwiftData
import SwiftUI

struct ReviewCorrectionView: View {
    let reviewCase: SmsReviewCase
    var sourceAlert: InboxAlert?
    var onFinished: (() -> Void)?

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Account.name) private var accounts: [Account]

    @State private var details: SmsReviewDetails?
    @State private var loadedAlert: InboxAlert?
    @State private var loading = true
    @State private var loadFailed = false
    @State private var saving = false
    @State private var draftSavedMessage: String?
    @State private var errorMessage: String?

    private var resolvedSourceAlert: InboxAlert? {
        sourceAlert ?? loadedAlert
    }

    var body: some View {
        Group {
            if let details, !details.rawBody.isEmpty {
                GroundedReviewCorrectionView(
                    details: details,
                    accounts: accounts,
                    sourceAlert: resolvedSourceAlert,
                    saving: saving,
                    draftSavedMessage: draftSavedMessage,
                    onResolve: resolveGrounded
                )
            } else if loading {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Loading saved alert…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(.systemGroupedBackground))
                .navigationTitle("Review transaction")
                .navigationBarTitleDisplayMode(.inline)
            } else {
                unavailableBody
            }
        }
        .task(id: "\(reviewCase.id.uuidString)-\(reviewCase.revision)") {
            await loadDetails()
        }
        .alert(
            "Could not complete review",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var unavailableBody: some View {
        Form {
            Section {
                Label("Review evidence is unavailable", systemImage: "exclamationmark.shield")
                    .font(.headline)
                Text(
                    loadFailed
                        ? "The saved review could not be loaded from local storage. Retry extraction or dismiss this alert."
                        : "The original alert text is no longer retained. Retry or mark this alert as not a transaction."
                )
                .foregroundStyle(.secondary)
            }
            if let resolvedSourceAlert {
                Section {
                    NavigationLink {
                        AlertProcessingDetailView(
                            alert: resolvedSourceAlert,
                            showReviewLink: false
                        )
                    } label: {
                        Label("Processing details", systemImage: "list.bullet.rectangle")
                    }
                    .accessibilityIdentifier("open-processing-details")
                }
            }
            Section {
                Button("Retry extraction") {
                    resolveGrounded(.retry, [], "current")
                }
                .disabled(saving)
                .accessibilityIdentifier("review-retry-extraction")

                Button("Not a transaction", role: .destructive) {
                    resolveGrounded(.reject, [], nil)
                }
                .disabled(saving)
                .accessibilityIdentifier("review-reject-alert")
            }
        }
        .navigationTitle("Review transaction")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func loadDetails() async {
        loading = details == nil
        loadFailed = false
        if sourceAlert == nil {
            let sourceAlertID = reviewCase.sourceAlertID
            var descriptor = FetchDescriptor<InboxAlert>(
                predicate: #Predicate { $0.id == sourceAlertID }
            )
            descriptor.fetchLimit = 1
            loadedAlert = try? modelContext.fetch(descriptor).first
        }
        do {
            let store = SmsProcessingStore.shared(for: modelContext.container)
            details = try await store.loadReviewDetails(reviewCaseID: reviewCase.id)
        } catch {
            loadFailed = true
            details = nil
        }
        loading = false
    }

    private func resolveGrounded(
        _ kind: ReviewCommandKind,
        _ corrections: [SmsFieldCorrection],
        _ retry: String?
    ) {
        guard !saving else { return }
        saving = true
        draftSavedMessage = nil
        let expectedRevision = details?.reviewRevision ?? reviewCase.revision
        let sourceAlertID = details?.sourceAlertID ?? reviewCase.sourceAlertID
        let operationID = details?.operationID ?? reviewCase.currentOperationID
        let command = ReviewCommand(
            actionID: UUID(),
            reviewCaseID: reviewCase.id,
            expectedRevision: expectedRevision,
            kind: kind,
            corrections: corrections,
            retryConfiguration: retry
        )
        let container = modelContext.container
        Task { @MainActor in
            defer { saving = false }
            do {
                let store = SmsProcessingStore.shared(for: container)
                _ = try await store.resolveReview(command)
                if kind == .retry, let retry {
                    _ = try await AlertIngestionService(context: modelContext).retry(
                        alertID: sourceAlertID,
                        parentOperationID: operationID,
                        configurationMode: retry
                    )
                }
                if kind == .saveDraft {
                    details = try await store.loadReviewDetails(reviewCaseID: reviewCase.id)
                    draftSavedMessage = "Draft saved locally."
                } else {
                    finish()
                }
            } catch SmsProcessingStoreError.invalidCommand {
                errorMessage = "The selected source evidence or account choice is not valid. Nothing was saved."
            } catch {
                errorMessage =
                    "The review changed or the local store was unavailable. Nothing was saved. Reopen the alert and try again."
            }
        }
    }

    private func finish() {
        if let onFinished {
            onFinished()
        } else {
            dismiss()
        }
    }
}
