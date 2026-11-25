import Foundation
import SwiftData

enum PocketFinancerSchemaV1: VersionedSchema {
    static let versionIdentifier = Schema.Version(1, 0, 0)

    static var models: [any PersistentModel.Type] {
        [InboxAlert.self, Transaction.self, Account.self]
    }
}

enum PocketFinancerSchemaV2: VersionedSchema {
    static let versionIdentifier = Schema.Version(2, 0, 0)

    static var models: [any PersistentModel.Type] {
        [InboxAlert.self, Transaction.self, Account.self, ExtractionRun.self]
    }
}

enum PocketFinancerSchemaV3: VersionedSchema {
    static let versionIdentifier = Schema.Version(3, 0, 0)

    static var models: [any PersistentModel.Type] {
        [
            InboxAlert.self,
            Transaction.self,
            Account.self,
            ExtractionRun.self,
            StructuredGenerationSnapshot.self,
        ]
    }
}

enum PocketFinancerSchemaV4: VersionedSchema {
    static let versionIdentifier = Schema.Version(4, 0, 0)

    static var models: [any PersistentModel.Type] {
        [
            InboxAlert.self,
            Transaction.self,
            Account.self,
            ExtractionRun.self,
            StructuredGenerationSnapshot.self,
            DeterministicFilterRun.self,
        ]
    }
}

enum PocketFinancerSchemaV5: VersionedSchema {
    static let versionIdentifier = Schema.Version(5, 0, 0)

    /// Frozen V5 shape. Keep this nested historical model unchanged so a store
    /// created by the first native-SMS schema remains recognizable.
    @Model
    final class SmsUserFeedbackEvent {
        @Attribute(.unique) var actionID: UUID
        var reviewCaseID: UUID
        var operationID: UUID
        var transactionRevisionID: UUID?
        var expectedReviewRevision: Int
        var resultingReviewRevision: Int
        var actionRawValue: String
        var actorClassRawValue: String
        var correctionsJSON: String
        var retryConfigurationRawValue: String?
        var canonicalLabelID: String?
        var canonicalLabelRevision: Int?
        var previousEventHash: String?
        var eventHash: String
        var createdAt: Date

        init(
            actionID: UUID,
            reviewCaseID: UUID,
            operationID: UUID,
            transactionRevisionID: UUID?,
            expectedReviewRevision: Int,
            resultingReviewRevision: Int,
            action: String,
            actorClass: String,
            correctionsJSON: String,
            retryConfiguration: String?,
            canonicalLabelID: String? = nil,
            canonicalLabelRevision: Int? = nil,
            previousEventHash: String?,
            eventHash: String,
            createdAt: Date = .now
        ) {
            self.actionID = actionID
            self.reviewCaseID = reviewCaseID
            self.operationID = operationID
            self.transactionRevisionID = transactionRevisionID
            self.expectedReviewRevision = expectedReviewRevision
            self.resultingReviewRevision = resultingReviewRevision
            self.actionRawValue = action
            self.actorClassRawValue = actorClass
            self.correctionsJSON = correctionsJSON
            self.retryConfigurationRawValue = retryConfiguration
            self.canonicalLabelID = canonicalLabelID
            self.canonicalLabelRevision = canonicalLabelRevision
            self.previousEventHash = previousEventHash
            self.eventHash = eventHash
            self.createdAt = createdAt
        }
    }

    static var models: [any PersistentModel.Type] {
        [
            InboxAlert.self,
            Transaction.self,
            Account.self,
            ExtractionRun.self,
            StructuredGenerationSnapshot.self,
            DeterministicFilterRun.self,
            SmsSourceMetadataEvent.self,
            SmsProcessingOperation.self,
            SmsProcessingAnalysis.self,
            SmsSelectorAttempt.self,
            SmsProcessingTraceEvent.self,
            SmsReconstructedResult.self,
            SmsPersistenceDecision.self,
            SmsReviewCase.self,
            PocketFinancerSchemaV5.SmsUserFeedbackEvent.self,
            SmsTransactionRevision.self,
            SmsAccountAlias.self,
            SmsLegacyTransactionSnapshot.self,
            SmsTraceImportReceipt.self,
        ]
    }
}

enum PocketFinancerSchemaV6: VersionedSchema {
    static let versionIdentifier = Schema.Version(6, 0, 0)

    static var models: [any PersistentModel.Type] {
        [
            InboxAlert.self,
            Transaction.self,
            Account.self,
            ExtractionRun.self,
            StructuredGenerationSnapshot.self,
            DeterministicFilterRun.self,
            SmsSourceMetadataEvent.self,
            SmsProcessingOperation.self,
            SmsProcessingAnalysis.self,
            SmsSelectorAttempt.self,
            SmsProcessingTraceEvent.self,
            SmsReconstructedResult.self,
            SmsPersistenceDecision.self,
            SmsReviewCase.self,
            SmsUserFeedbackEvent.self,
            SmsTransactionRevision.self,
            SmsAccountAlias.self,
            SmsLegacyTransactionSnapshot.self,
            SmsTraceImportReceipt.self,
        ]
    }
}

/// V7 is an explicit durable boundary for the v4 extractor. Historical
/// snapshots retain their versioned payloads and are never reinterpreted.
enum PocketFinancerSchemaV7: VersionedSchema {
    static let versionIdentifier = Schema.Version(7, 0, 0)
    static var models: [any PersistentModel.Type] {
        PocketFinancerSchemaV6.models + [SmsContractReleaseState.self]
    }
}

enum PocketFinancerMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [
            PocketFinancerSchemaV1.self,
            PocketFinancerSchemaV2.self,
            PocketFinancerSchemaV3.self,
            PocketFinancerSchemaV4.self,
            PocketFinancerSchemaV5.self,
            PocketFinancerSchemaV6.self,
            PocketFinancerSchemaV7.self,
        ]
    }

    static var stages: [MigrationStage] {
        [
            .lightweight(
                fromVersion: PocketFinancerSchemaV1.self,
                toVersion: PocketFinancerSchemaV2.self
            ),
            .lightweight(
                fromVersion: PocketFinancerSchemaV2.self,
                toVersion: PocketFinancerSchemaV3.self
            ),
            .lightweight(
                fromVersion: PocketFinancerSchemaV3.self,
                toVersion: PocketFinancerSchemaV4.self
            ),
            .lightweight(
                fromVersion: PocketFinancerSchemaV4.self,
                toVersion: PocketFinancerSchemaV5.self
            ),
            .lightweight(
                fromVersion: PocketFinancerSchemaV5.self,
                toVersion: PocketFinancerSchemaV6.self
            ),
            .lightweight(
                fromVersion: PocketFinancerSchemaV6.self,
                toVersion: PocketFinancerSchemaV7.self
            ),
        ]
    }
}
