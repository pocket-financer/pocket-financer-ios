import Foundation
import SwiftData

enum IngestionDisposition: String, Sendable {
    case imported
    case queued
    case alreadyProcessing = "already_processing"
    case processingIncomplete = "processing_incomplete"
    case needsReview
    case rejected
    case duplicate
}

struct IngestionReceipt: Equatable, Sendable {
    let alertID: UUID
    let disposition: IngestionDisposition

    nonisolated var safeDialog: String {
        switch disposition {
        case .imported:
            "Transaction imported locally."
        case .queued:
            "Alert saved locally for processing later."
        case .alreadyProcessing:
            "This saved alert is already being processed locally. No second model attempt was started."
        case .processingIncomplete:
            "Alert saved locally, but processing did not finish. Its evidence remains available for retry."
        case .needsReview:
            "Alert saved and marked for review."
        case .rejected:
            "Alert checked locally. No transaction was added."
        case .duplicate:
            "A similar alert was saved for duplicate review. Its original evidence was preserved."
        }
    }
}

enum AlertIngestionError: Error, Equatable {
    case alertNotFound
    case inputTooLarge
    case persistenceFailed
    case storeUnavailable
}

@MainActor
final class AlertIngestionService {
    static let duplicateWindow: TimeInterval = 15
    static let automaticAttemptLimit = 3
    static let maximumBodyBytes = 16_384
    static let maximumSenderBytes = 512
    static let maximumSourceApplicationBytes = 256

    private let context: ModelContext
    private let contextSaver: @MainActor (ModelContext) throws -> Void
    private let directSelector: any DirectCandidateSelecting
    private let smsExtractor: any FoundationSmsExtracting
    private let extractorEligibilityOverride: Bool?

    /// Main-actor reentrancy permits another service instance to enter while a parser
    /// request is suspended. A process-wide token prevents a second attempt for the same
    /// durable alert. The epoch invalidates both active claims and queue batches captured
    /// before an owner erase. These values intentionally reset after process restart so a
    /// persisted `.processing` alert can be recovered.
    private struct ProcessingClaim: Equatable, Sendable {
        let token: UUID
        let epoch: UInt64
    }

    private struct OwnerState: Equatable {
        let alertUpdatedAt: Date
        let transactionID: UUID?
        let transactionUpdatedAt: Date?
        let transactionWasEdited: Bool?
    }

    private static var processingClaims: [UUID: ProcessingClaim] = [:]
    private static var processingEpoch: UInt64 = 0

    init(
        context: ModelContext,
        contextSaver: @escaping @MainActor (ModelContext) throws -> Void = { try $0.save() },
        directSelector: any DirectCandidateSelecting = FoundationDirectCandidateSelector(),
        smsExtractor: any FoundationSmsExtracting = FoundationSmsExtractor(),
        extractorEligibilityOverride: Bool? = nil
    ) {
        self.context = context
        self.contextSaver = contextSaver
        self.directSelector = directSelector
        self.smsExtractor = smsExtractor
        self.extractorEligibilityOverride = extractorEligibilityOverride
    }

    static func enqueueLive(
        body: String,
        sender: String?,
        receivedAt: Date?,
        sourceApplication: String?,
        origin: AlertOrigin,
        openDatabase: @MainActor () async throws -> AppDatabase = {
            try await AppDatabase.openShared()
        }
    ) async throws -> IngestionReceipt {
        let database: AppDatabase
        do {
            database = try await openDatabase()
            try database.refreshFileProtection()
        } catch {
            throw AlertIngestionError.storeUnavailable
        }

        let service = AlertIngestionService(context: database.container.mainContext)
        return try service.enqueue(
            body: body,
            sender: sender,
            receivedAt: receivedAt,
            sourceApplication: sourceApplication,
            origin: origin
        )
    }

    static func ingestLive(
        body: String,
        sender: String?,
        receivedAt: Date?,
        sourceApplication: String?,
        origin: AlertOrigin,
        openDatabase: @MainActor () async throws -> AppDatabase = {
            try await AppDatabase.openShared()
        }
    ) async throws -> IngestionReceipt {
        let database: AppDatabase
        do {
            database = try await openDatabase()
            try database.refreshFileProtection()
        } catch {
            throw AlertIngestionError.storeUnavailable
        }

        return try await AlertIngestionService(context: database.container.mainContext).ingest(
            body: body,
            sender: sender,
            receivedAt: receivedAt,
            sourceApplication: sourceApplication,
            origin: origin
        )
    }

    /// Durably saves or deduplicates an alert without filtering or invoking the model.
    /// This is the complete background App Intent boundary.
    func enqueue(
        body: String,
        sender: String?,
        receivedAt: Date?,
        sourceApplication: String?,
        origin: AlertOrigin
    ) throws -> IngestionReceipt {
        let resolvedSender = sender ?? ""
        let resolvedDate = receivedAt ?? .now
        guard
            body.utf8.count <= Self.maximumBodyBytes,
            resolvedSender.utf8.count <= Self.maximumSenderBytes,
            (sourceApplication?.utf8.count ?? 0) <= Self.maximumSourceApplicationBytes
        else {
            throw AlertIngestionError.inputTooLarge
        }
        let digest = AlertSourceIdentity.contentDigest(sender: resolvedSender, body: body)
        let sourceIdentity = AlertSourceIdentity.fingerprint(
            sender: resolvedSender,
            body: body,
            receivedAt: resolvedDate,
            sourceApplication: sourceApplication
        )

        let duplicate = try findDuplicate(contentDigest: digest, receivedAt: resolvedDate)
        let alert = InboxAlert(
            sourceIdentity: sourceIdentity,
            contentDigest: digest,
            origin: origin,
            sourceApplication: sourceApplication,
            sender: resolvedSender,
            rawBody: body,
            receivedAt: resolvedDate
        )
        context.insert(alert)
        let metadataPayload =
            #"{"sender_supplied":\#(sender != nil),"timestamp_supplied":\#(receivedAt != nil),"source_application_supplied":\#(sourceApplication != nil)}"#
        context.insert(
            SmsSourceMetadataEvent(
                sourceAlertID: alert.id,
                sequence: 0,
                kind: "admission_optional_field_presence",
                payloadJSON: metadataPayload,
                occurredAt: alert.createdAt
            ))

        if let duplicate {
            // Equal content within a short time window is only a heuristic.
            // Preserve both admissions and require an explicit user decision.
            alert.status = .needsReview
            alert.duplicateOfAlertID = duplicate.id
            alert.lastErrorCode = "possible_duplicate_heuristic_match"
            try save()
            return IngestionReceipt(alertID: alert.id, disposition: .duplicate)
        }

        // This is the crash-recovery boundary: evidence is committed before filtering
        // or model work, and a successful return always means it can be processed later.
        try save()
        return IngestionReceipt(alertID: alert.id, disposition: .queued)
    }

    func ingest(
        body: String,
        sender: String?,
        receivedAt: Date?,
        sourceApplication: String?,
        origin: AlertOrigin
    ) async throws -> IngestionReceipt {
        let queued = try enqueue(
            body: body,
            sender: sender,
            receivedAt: receivedAt,
            sourceApplication: sourceApplication,
            origin: origin
        )
        guard queued.disposition == .queued, let alert = try findAlert(id: queued.alertID) else {
            return queued
        }

        do {
            return try await classifyAndProcessIfClaimed(alert, allowBeyondAutomaticAttemptLimit: true)
                ?? queued
        } catch {
            // The enqueue save already succeeded. Never tell the foreground owner that
            // evidence was not saved merely because a later processing save failed.
            return IngestionReceipt(alertID: queued.alertID, disposition: .processingIncomplete)
        }
    }

    func retry(
        alertID: UUID,
        parentOperationID: UUID? = nil,
        configurationMode: String = "current"
    ) async throws -> IngestionReceipt {
        guard ["original", "current"].contains(configurationMode) else {
            throw AlertIngestionError.persistenceFailed
        }
        guard let alert = try findAlert(id: alertID) else { throw AlertIngestionError.alertNotFound }
        guard !alert.rawBody.isEmpty else {
            return IngestionReceipt(alertID: alert.id, disposition: .rejected)
        }
        do {
            return try await classifyAndProcessIfClaimed(
                alert,
                allowBeyondAutomaticAttemptLimit: true,
                retryParentOperationID: parentOperationID,
                retryConfigurationMode: configurationMode
            )
                ?? IngestionReceipt(alertID: alert.id, disposition: .alreadyProcessing)
        } catch {
            return IngestionReceipt(alertID: alert.id, disposition: .processingIncomplete)
        }
    }

    @discardableResult
    func processPending(limit: Int = 8, includeNeedsReview: Bool = false) async -> Int {
        guard limit > 0 else { return 0 }
        let batchEpoch = Self.processingEpoch
        let pendingStatus = AlertStatus.pending.rawValue
        let processingStatus = AlertStatus.processing.rawValue
        let predicate: Predicate<InboxAlert>
        if includeNeedsReview {
            let importedStatus = AlertStatus.imported.rawValue
            let rejectedStatus = AlertStatus.rejected.rawValue
            let duplicateStatus = AlertStatus.duplicate.rawValue
            predicate = #Predicate { alert in
                alert.statusRawValue != importedStatus
                    && alert.statusRawValue != rejectedStatus
                    && alert.statusRawValue != duplicateStatus
                    && alert.rawBody != ""
            }
        } else {
            predicate = #Predicate { alert in
                (alert.statusRawValue == pendingStatus
                    || alert.statusRawValue == processingStatus)
                    && alert.rawBody != ""
            }
        }
        var descriptor = FetchDescriptor<InboxAlert>(
            predicate: predicate,
            sortBy: [SortDescriptor(\InboxAlert.createdAt)]
        )
        descriptor.fetchLimit = limit
        guard let alerts = try? context.fetch(descriptor) else { return 0 }
        let eligibleAlertIDs = alerts.map(\.id)

        var completed = 0
        for alertID in eligibleAlertIDs {
            guard !Task.isCancelled, Self.processingEpoch == batchEpoch else { break }
            guard let alert = try? findAlert(id: alertID) else { continue }
            do {
                if try await classifyAndProcessIfClaimed(
                    alert,
                    allowBeyondAutomaticAttemptLimit: includeNeedsReview,
                    expectedProcessingEpoch: batchEpoch
                ) != nil {
                    completed += 1
                }
            } catch {
                guard
                    Self.processingEpoch == batchEpoch,
                    let durableAlert = try? findAlert(id: alertID)
                else { break }
                durableAlert.status = .pending
                durableAlert.lastErrorCode = "persistence_failed"
                durableAlert.updatedAt = .now
                try? save()
            }
        }
        return completed
    }

    private func classifyAndProcessIfClaimed(
        _ alert: InboxAlert,
        allowBeyondAutomaticAttemptLimit: Bool,
        expectedProcessingEpoch: UInt64? = nil,
        retryParentOperationID: UUID? = nil,
        retryConfigurationMode: String = "current"
    ) async throws -> IngestionReceipt? {
        let alertID = alert.id
        guard
            let preflightAlert = try findAlert(id: alertID),
            !Task.isCancelled,
            Self.canProcess(
                preflightAlert,
                allowNeedsReview: allowBeyondAutomaticAttemptLimit
            )
        else { return nil }
        let ownerStateAtEntry = try ownerState(for: preflightAlert)

        guard
            let currentAlert = try findAlert(id: alertID),
            !Task.isCancelled
        else { return nil }
        guard try ownerState(for: currentAlert) == ownerStateAtEntry else {
            return IngestionReceipt(
                alertID: alertID,
                disposition: Self.currentDisposition(for: currentAlert)
            )
        }
        guard
            Self.canProcess(
                currentAlert,
                allowNeedsReview: allowBeyondAutomaticAttemptLimit
            )
        else { return nil }
        guard
            let claim = Self.acquireClaim(
                for: alertID,
                expectedProcessingEpoch: expectedProcessingEpoch
            )
        else { return nil }
        defer { Self.releaseClaim(for: alertID, claim: claim) }

        if !allowBeyondAutomaticAttemptLimit,
            currentAlert.attemptCount >= Self.automaticAttemptLimit
        {
            currentAlert.status = .needsReview
            currentAlert.lastErrorCode = "automatic_retry_limit_reached"
            currentAlert.updatedAt = .now
            try save()
            return IngestionReceipt(alertID: currentAlert.id, disposition: .needsReview)
        }

        guard let currentPrimaryCurrency = PrimaryCurrencySettings.confirmedCode else {
            currentAlert.status = .pending
            currentAlert.lastErrorCode = "configuration_primary_currency_required"
            currentAlert.updatedAt = .now
            try save()
            return IngestionReceipt(alertID: currentAlert.id, disposition: .queued)
        }

        let retrySettings = try retryConfiguration(
            parentOperationID: retryParentOperationID,
            mode: retryConfigurationMode,
            currentPrimaryCurrency: currentPrimaryCurrency
        )
        let originalContract = try originalConfigurationContract(
            parentOperationID: retryParentOperationID,
            mode: retryConfigurationMode
        )
        if let originalContract,
            ![
                "pocketfinancer.processing-config/2",
                "pocketfinancer.processing-config/4",
            ].contains(originalContract)
        {
            currentAlert.status = .needsReview
            currentAlert.lastErrorCode = "original_configuration_adapter_unavailable"
            currentAlert.updatedAt = .now
            try save()
            return IngestionReceipt(alertID: currentAlert.id, disposition: .needsReview)
        }

        currentAlert.status = .processing
        currentAlert.attemptCount += 1
        currentAlert.lastAttemptAt = .now
        currentAlert.updatedAt = .now
        try save()

        let processingStore = SmsProcessingStore(modelContainer: context.container)
        let sourceReference = AdmittedMessageRef(
            sourceID: currentAlert.id,
            admissionReceiptID: currentAlert.id,
            sourceDigest: CanonicalJSON.sha256(currentAlert.rawBody)
        )
        let operationTrigger =
            retryParentOperationID == nil
            ? (allowBeyondAutomaticAttemptLimit ? "foreground_or_user" : "automatic_recovery")
            : "retry"
        let useLegacyOriginal = originalContract == "pocketfinancer.processing-config/2"
        let outcome: SmsProcessingOutcome
        if useLegacyOriginal {
            let snapshot = try SmsOperationSnapshotFactory(context: context).create(
                sourceAlertID: currentAlert.id,
                parentOperationID: retryParentOperationID,
                trigger: operationTrigger,
                primaryCurrency: retrySettings.primaryCurrency,
                enabledProfiles: retrySettings.enabledProfiles,
                selectorModelIdentifier: "apple-system-language-model",
                selectorRuntimeVersion: ProcessInfo.processInfo.operatingSystemVersionString
            )
            let coordinator = DefaultSmsProcessingCoordinator(
                store: processingStore,
                selector: directSelector,
                accountResolver: { evidence in
                    try GroundedAccountResolver(context: self.context).resolve(evidence)
                }
            )
            outcome = await coordinator.process(
                source: sourceReference,
                operation: snapshot,
                observer: NoOpSmsProcessingObserver()
            )
        } else {
            let snapshot = try SmsV4OperationSnapshotFactory(context: context).create(
                sourceAlertID: currentAlert.id,
                parentOperationID: retryParentOperationID,
                trigger: operationTrigger,
                primaryCurrency: retrySettings.primaryCurrency,
                enabledProfiles: retrySettings.enabledProfiles,
                extractorEligibilityOverride: extractorEligibilityOverride
            )
            let coordinator = SmsV4ProcessingCoordinator(
                store: processingStore,
                extractor: smsExtractor,
                accountResolver: { evidence in
                    try GroundedAccountResolver(context: self.context).resolve(evidence)
                }
            )
            outcome = await coordinator.process(
                source: sourceReference,
                operation: snapshot,
                observer: NoOpSmsProcessingObserver()
            )
        }
        guard Self.ownsClaim(for: alertID, claim: claim) else {
            return IngestionReceipt(alertID: alertID, disposition: .processingIncomplete)
        }
        switch outcome {
        case .terminallyDiscarded(_, let reason):
            // The coordinator uses an independent model context. Mirror the erasure in
            // this context before saving the foreground status so stale source fields
            // can never be written back over the durable discard.
            currentAlert.eraseSensitiveEvidence()
            currentAlert.status = .rejected
            currentAlert.lastErrorCode = reason
            currentAlert.updatedAt = .now
            try save()
            return IngestionReceipt(alertID: alertID, disposition: .rejected)
        case .retainedForReview(_, _, let reasons):
            currentAlert.status = .needsReview
            currentAlert.lastErrorCode = reasons.first
            currentAlert.updatedAt = .now
            try save()
            return IngestionReceipt(alertID: alertID, disposition: .needsReview)
        case .persisted:
            currentAlert.status = .imported
            currentAlert.lastErrorCode = nil
            currentAlert.updatedAt = .now
            try save()
            return IngestionReceipt(alertID: alertID, disposition: .imported)
        case .retryableFailure(_, _, let reason), .stopped(_, _, let reason):
            currentAlert.status = .needsReview
            currentAlert.lastErrorCode = reason
            currentAlert.updatedAt = .now
            try save()
            return IngestionReceipt(alertID: alertID, disposition: .needsReview)
        }
    }

    private func retryConfiguration(
        parentOperationID: UUID?,
        mode: String,
        currentPrimaryCurrency: String
    ) throws -> (primaryCurrency: String, enabledProfiles: [String]) {
        guard mode == "original", let parentOperationID else {
            return (
                currentPrimaryCurrency,
                currentPrimaryCurrency == "INR" ? ["core-en", "india"] : ["core-en"]
            )
        }
        let parentID = parentOperationID
        guard
            let operation = try context.fetch(
                FetchDescriptor<SmsProcessingOperation>(
                    predicate: #Predicate { $0.id == parentID }
                )
            ).first,
            let document = try? JSONSerialization.jsonObject(
                with: Data(operation.configurationJSON.utf8)
            ) as? [String: Any],
            let currencyContext = document["currency_context"] as? [String: Any],
            let primaryCurrency = currencyContext["primary_currency"] as? String,
            CurrencyFormatter.supportedScales[primaryCurrency] != nil,
            let enabledProfiles = currencyContext["enabled_profile_ids"] as? [String],
            !enabledProfiles.isEmpty,
            enabledProfiles.allSatisfy({ ["core-en", "india"].contains($0) })
        else { throw AlertIngestionError.persistenceFailed }
        return (primaryCurrency, enabledProfiles)
    }

    private func originalConfigurationContract(
        parentOperationID: UUID?,
        mode: String
    ) throws -> String? {
        guard mode == "original", let parentOperationID else { return nil }
        let parentID = parentOperationID
        guard
            let operation = try context.fetch(
                FetchDescriptor<SmsProcessingOperation>(
                    predicate: #Predicate { $0.id == parentID }
                )
            ).first,
            let document = try? JSONSerialization.jsonObject(
                with: Data(operation.configurationJSON.utf8)
            ) as? [String: Any],
            let contract = document["contract"] as? String
        else { throw AlertIngestionError.persistenceFailed }
        return contract
    }

    private func findDuplicate(contentDigest: String, receivedAt: Date) throws -> InboxAlert? {
        let descriptor = FetchDescriptor<InboxAlert>(sortBy: [SortDescriptor(\InboxAlert.receivedAt, order: .reverse)])
        return try context.fetch(descriptor).first { candidate in
            candidate.contentDigest == contentDigest
                && candidate.status != .duplicate
                && abs(candidate.receivedAt.timeIntervalSince(receivedAt)) <= Self.duplicateWindow
        }
    }

    private func findAlert(id: UUID) throws -> InboxAlert? {
        let targetID = id
        var descriptor = FetchDescriptor<InboxAlert>(
            predicate: #Predicate { alert in
                alert.id == targetID
            }
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    private static func canProcess(
        _ alert: InboxAlert,
        allowNeedsReview: Bool
    ) -> Bool {
        switch alert.status {
        case .pending, .processing:
            true
        case .needsReview:
            allowNeedsReview
        case .imported, .rejected, .duplicate:
            false
        }
    }

    private static func currentDisposition(for alert: InboxAlert) -> IngestionDisposition {
        switch alert.status {
        case .pending, .processing:
            .queued
        case .imported:
            .imported
        case .needsReview:
            .needsReview
        case .rejected:
            .rejected
        case .duplicate:
            .duplicate
        }
    }

    private func ownerState(for alert: InboxAlert) throws -> OwnerState {
        let transaction = try findTransaction(for: alert)
        return OwnerState(
            alertUpdatedAt: alert.updatedAt,
            transactionID: alert.transactionID,
            transactionUpdatedAt: transaction?.updatedAt,
            transactionWasEdited: transaction?.isEdited
        )
    }

    private func findTransaction(for alert: InboxAlert) throws -> Transaction? {
        guard let transactionID = alert.transactionID else { return nil }
        return try findTransaction(id: transactionID)
    }

    private func findTransaction(id: UUID) throws -> Transaction? {
        try context.fetch(FetchDescriptor<Transaction>()).first { $0.id == id }
    }

    private func save() throws {
        do {
            try contextSaver(context)
        } catch {
            context.rollback()
            throw AlertIngestionError.persistenceFailed
        }
    }

    private static func acquireClaim(
        for alertID: UUID,
        expectedProcessingEpoch: UInt64?
    ) -> ProcessingClaim? {
        guard
            expectedProcessingEpoch == nil || expectedProcessingEpoch == processingEpoch,
            processingClaims[alertID] == nil
        else { return nil }
        let claim = ProcessingClaim(token: UUID(), epoch: processingEpoch)
        processingClaims[alertID] = claim
        return claim
    }

    private static func ownsClaim(for alertID: UUID, claim: ProcessingClaim) -> Bool {
        claim.epoch == processingEpoch && processingClaims[alertID] == claim
    }

    private static func releaseClaim(for alertID: UUID, claim: ProcessingClaim) {
        guard ownsClaim(for: alertID, claim: claim) else { return }
        processingClaims[alertID] = nil
    }

    static func invalidateAllProcessingClaims() {
        processingEpoch &+= 1
        processingClaims.removeAll()
    }
}
