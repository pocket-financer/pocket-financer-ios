import Foundation
import SwiftData

enum SmsAccountResolution: Equatable, Sendable {
    case missing
    case unresolved
    case ambiguous(accountIDs: [UUID])
    case unique(accountID: UUID)
}

@MainActor
struct GroundedAccountResolver {
    let context: ModelContext

    func resolve(_ sourceGroundedIdentifier: String?) throws -> SmsAccountResolution {
        guard let sourceGroundedIdentifier else { return .missing }
        guard let reference = SmsExtractorNormalizer.normalizeAccount(sourceGroundedIdentifier)
        else { return .unresolved }
        let normalized = reference.contains("@") ? "vpa:\(reference)" : "suffix:\(reference)"
        let aliasHash = CanonicalJSON.sha256(normalized)
        let confirmed = true
        let scope = "owned_account_v1"
        let aliases = try context.fetch(
            FetchDescriptor<SmsAccountAlias>(
                predicate: #Predicate {
                    $0.normalizedAliasHash == aliasHash
                        && $0.confirmedByUser == confirmed
                        && $0.matchingScopeRawValue == scope
                })
        )
        let existingAccountIDs = Set(try context.fetch(FetchDescriptor<Account>()).map(\.id))
        let accountIDs = Array(Set(aliases.map(\.accountID)).intersection(existingAccountIDs)).sorted {
            $0.uuidString < $1.uuidString
        }
        return switch accountIDs.count {
        case 0: .unresolved
        case 1: .unique(accountID: accountIDs[0])
        default: .ambiguous(accountIDs: accountIDs)
        }
    }
}
