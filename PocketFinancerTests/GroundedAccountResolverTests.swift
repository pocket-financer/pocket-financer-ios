import SwiftData
import XCTest

@testable import PocketFinancer

@MainActor
final class GroundedAccountResolverTests: XCTestCase {
    func testMaskedSuffixResolvesOnlyConfirmedOwnedAliasWithLiveAccount() throws {
        let database = try AppDatabase(inMemory: true)
        let context = database.container.mainContext
        let account = Account(
            name: "A/c XX1234", bank: "Synthetic Bank", kind: .account, suffix: "1234"
        )
        let aliasHash = CanonicalJSON.sha256("suffix:1234")
        context.insert(account)
        context.insert(
            SmsAccountAlias(
                accountID: account.id,
                normalizedAliasHash: aliasHash,
                aliasKind: "suffix",
                matchingScope: "owned_account_v1",
                confirmedByUser: true
            ))
        try context.save()

        let resolution = try GroundedAccountResolver(context: context).resolve(
            " account **１２３４ "
        )

        guard case .unique(let accountID) = resolution else {
            return XCTFail("Expected one confirmed live account")
        }
        XCTAssertEqual(accountID, account.id)
    }

    func testAmbiguousSourceReferenceDoesNotResolve() throws {
        let database = try AppDatabase(inMemory: true)
        let resolution = try GroundedAccountResolver(
            context: database.container.mainContext
        ).resolve("accounts **1234 and **5678")

        XCTAssertEqual(resolution, .unresolved)
    }

    func testMultipleLiveAccountsForOneConfirmedAliasAreAmbiguous() throws {
        let database = try AppDatabase(inMemory: true)
        let context = database.container.mainContext
        let aliasHash = CanonicalJSON.sha256("suffix:1234")
        let accounts = [
            Account(name: "A/c A XX1234", bank: "Synthetic A", kind: .account, suffix: "1234"),
            Account(name: "A/c B XX1234", bank: "Synthetic B", kind: .account, suffix: "1234"),
        ]
        for account in accounts {
            context.insert(account)
            context.insert(
                SmsAccountAlias(
                    accountID: account.id,
                    normalizedAliasHash: aliasHash,
                    aliasKind: "suffix",
                    matchingScope: "owned_account_v1",
                    confirmedByUser: true
                ))
        }
        try context.save()

        let resolution = try GroundedAccountResolver(context: context).resolve("**1234")

        guard case .ambiguous(let accountIDs) = resolution else {
            return XCTFail("Expected an account-integrity ambiguity")
        }
        XCTAssertEqual(Set(accountIDs), Set(accounts.map(\.id)))
    }
}
