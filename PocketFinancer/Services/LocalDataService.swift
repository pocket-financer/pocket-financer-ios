import Foundation
import SwiftData

struct StorageDiagnostic: Equatable, Sendable {
    let pending: Int
    let needsReview: Int
    let imported: Int
    let rejected: Int
    let duplicates: Int
}

@MainActor
struct LocalDataService {
    let context: ModelContext

    func diagnostics() -> StorageDiagnostic {
        let alerts = (try? context.fetch(FetchDescriptor<InboxAlert>())) ?? []
        return StorageDiagnostic(
            pending: alerts.count { $0.status == .pending || $0.status == .processing },
            needsReview: alerts.count { $0.status == .needsReview },
            imported: alerts.count { $0.status == .imported },
            rejected: alerts.count { $0.status == .rejected },
            duplicates: alerts.count { $0.status == .duplicate }
        )
    }

    func eraseAll() throws {
        // Prevent suspended parser work from writing snapshots or ledger rows after the
        // owner has completed an erase. Existing model work may finish in memory, but it
        // no longer owns permission to mutate the protected store.
        AlertIngestionService.invalidateAllProcessingClaims()

        do {
            for receipt in try context.fetch(FetchDescriptor<SmsTraceImportReceipt>()) {
                context.delete(receipt)
            }
            for alias in try context.fetch(FetchDescriptor<SmsAccountAlias>()) {
                context.delete(alias)
            }
            for revision in try context.fetch(FetchDescriptor<SmsTransactionRevision>()) {
                context.delete(revision)
            }
            for snapshot in try context.fetch(FetchDescriptor<SmsLegacyTransactionSnapshot>()) {
                context.delete(snapshot)
            }
            for feedback in try context.fetch(FetchDescriptor<SmsUserFeedbackEvent>()) {
                context.delete(feedback)
            }
            for review in try context.fetch(FetchDescriptor<SmsReviewCase>()) {
                context.delete(review)
            }
            for decision in try context.fetch(FetchDescriptor<SmsPersistenceDecision>()) {
                context.delete(decision)
            }
            for result in try context.fetch(FetchDescriptor<SmsReconstructedResult>()) {
                context.delete(result)
            }
            for event in try context.fetch(FetchDescriptor<SmsProcessingTraceEvent>()) {
                context.delete(event)
            }
            for attempt in try context.fetch(FetchDescriptor<SmsSelectorAttempt>()) {
                context.delete(attempt)
            }
            for analysis in try context.fetch(FetchDescriptor<SmsProcessingAnalysis>()) {
                context.delete(analysis)
            }
            for operation in try context.fetch(FetchDescriptor<SmsProcessingOperation>()) {
                context.delete(operation)
            }
            for metadata in try context.fetch(FetchDescriptor<SmsSourceMetadataEvent>()) {
                context.delete(metadata)
            }
            for filterRun in try context.fetch(FetchDescriptor<DeterministicFilterRun>()) {
                context.delete(filterRun)
            }
            for snapshot in try context.fetch(FetchDescriptor<StructuredGenerationSnapshot>()) {
                context.delete(snapshot)
            }
            for run in try context.fetch(FetchDescriptor<ExtractionRun>()) {
                context.delete(run)
            }
            for transaction in try context.fetch(FetchDescriptor<Transaction>()) {
                context.delete(transaction)
            }
            for account in try context.fetch(FetchDescriptor<Account>()) {
                context.delete(account)
            }
            for alert in try context.fetch(FetchDescriptor<InboxAlert>()) {
                context.delete(alert)
            }
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
    }
}
