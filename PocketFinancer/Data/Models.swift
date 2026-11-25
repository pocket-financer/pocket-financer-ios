import Foundation
import SwiftData

enum AlertStatus: String, CaseIterable, Sendable {
    case pending
    case processing
    case imported
    case needsReview
    case rejected
    case duplicate
}

enum AlertOrigin: String, CaseIterable, Sendable {
    case shortcut
    case manual
}

enum TransactionDirection: String, CaseIterable, Identifiable, Sendable {
    case debit
    case credit

    var id: String { rawValue }
}

enum ReviewState: String, CaseIterable, Sendable {
    case confirmed
    case needsReview
}

enum AccountKind: String, CaseIterable, Identifiable, Sendable {
    case account
    case card
    case unknown

    var id: String { rawValue }
}

@Model
final class InboxAlert {
    @Attribute(.unique) var id: UUID
    var sourceIdentity: String
    var contentDigest: String
    var originRawValue: String
    var sourceApplication: String?
    var normalizedSender: String
    var sender: String
    var rawBody: String
    var receivedAt: Date
    var createdAt: Date
    var updatedAt: Date
    var statusRawValue: String
    var attemptCount: Int
    var lastAttemptAt: Date?
    var lastErrorCode: String?
    var rejectionCode: String?
    var duplicateOfAlertID: UUID?
    var parserName: String?
    var transactionID: UUID?

    init(
        id: UUID = UUID(),
        sourceIdentity: String,
        contentDigest: String,
        origin: AlertOrigin,
        sourceApplication: String?,
        sender: String,
        rawBody: String,
        receivedAt: Date,
        now: Date = .now
    ) {
        self.id = id
        self.sourceIdentity = sourceIdentity
        self.contentDigest = contentDigest
        self.originRawValue = origin.rawValue
        self.sourceApplication = sourceApplication
        self.normalizedSender = AlertSourceIdentity.normalizedSender(sender)
        self.sender = sender
        self.rawBody = rawBody
        self.receivedAt = receivedAt
        self.createdAt = now
        self.updatedAt = now
        self.statusRawValue = AlertStatus.pending.rawValue
        self.attemptCount = 0
    }

    var status: AlertStatus {
        get { AlertStatus(rawValue: statusRawValue) ?? .needsReview }
        set { statusRawValue = newValue.rawValue }
    }

    var origin: AlertOrigin {
        get { AlertOrigin(rawValue: originRawValue) ?? .shortcut }
        set { originRawValue = newValue.rawValue }
    }

    func eraseSensitiveEvidence() {
        let erasedIdentity = "erased:\(id.uuidString.lowercased())"
        sourceIdentity = erasedIdentity
        contentDigest = erasedIdentity
        sender = ""
        rawBody = ""
        sourceApplication = nil
        normalizedSender = ""
        updatedAt = .now
    }
}

@Model
final class Transaction {
    @Attribute(.unique) var id: UUID
    var amountMinorUnits: Int64
    var currencyCode: String
    var merchant: String
    var occurredAt: Date
    var directionRawValue: String
    var accountID: UUID?
    var accountLabel: String?
    var isEdited: Bool
    var createdAt: Date
    var updatedAt: Date
    var parserName: String
    var reviewStateRawValue: String
    var sourceAlertID: UUID
    var amountEvidenceText: String
    var dateEvidenceText: String?

    init(
        id: UUID = UUID(),
        amountMinorUnits: Int64,
        currencyCode: String,
        merchant: String,
        occurredAt: Date,
        direction: TransactionDirection,
        accountID: UUID?,
        accountLabel: String?,
        isEdited: Bool = false,
        parserName: String,
        reviewState: ReviewState,
        sourceAlertID: UUID,
        amountEvidenceText: String,
        dateEvidenceText: String?,
        now: Date = .now
    ) {
        self.id = id
        self.amountMinorUnits = amountMinorUnits
        self.currencyCode = currencyCode
        self.merchant = merchant
        self.occurredAt = occurredAt
        self.directionRawValue = direction.rawValue
        self.accountID = accountID
        self.accountLabel = accountLabel
        self.isEdited = isEdited
        self.createdAt = now
        self.updatedAt = now
        self.parserName = parserName
        self.reviewStateRawValue = reviewState.rawValue
        self.sourceAlertID = sourceAlertID
        self.amountEvidenceText = amountEvidenceText
        self.dateEvidenceText = dateEvidenceText
    }

    var direction: TransactionDirection {
        get { TransactionDirection(rawValue: directionRawValue) ?? .debit }
        set { directionRawValue = newValue.rawValue }
    }

    var reviewState: ReviewState {
        get { ReviewState(rawValue: reviewStateRawValue) ?? .needsReview }
        set { reviewStateRawValue = newValue.rawValue }
    }

    var decimalAmount: Decimal {
        let scale = CurrencyFormatter.supportedScales[currencyCode.uppercased()] ?? 2
        let divisor = pow(Decimal(10), scale)
        return Decimal(amountMinorUnits) / divisor
    }
}

nonisolated private func pow(_ base: Decimal, _ exponent: Int) -> Decimal {
    guard exponent > 0 else { return 1 }
    return (0..<exponent).reduce(Decimal(1)) { partial, _ in partial * base }
}

@Model
final class Account {
    @Attribute(.unique) var id: UUID
    var name: String
    var bank: String
    var kindRawValue: String
    var suffix: String?
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        bank: String,
        kind: AccountKind,
        suffix: String?,
        now: Date = .now
    ) {
        self.id = id
        self.name = name
        self.bank = bank
        self.kindRawValue = kind.rawValue
        self.suffix = suffix
        self.createdAt = now
        self.updatedAt = now
    }

    var kind: AccountKind {
        get { AccountKind(rawValue: kindRawValue) ?? .unknown }
        set { kindRawValue = newValue.rawValue }
    }
}
