import Foundation
import SwiftData
import XCTest

@testable import PocketFinancer

@MainActor
final class GroundedAccountResolverTests: XCTestCase {
    func testNilIdentifierReturnsMissing() throws {
        let database = try AppDatabase(inMemory: true)
        let resolution = try GroundedAccountResolver(context: database.container.mainContext).resolve(nil)

        XCTAssertEqual(resolution, .missing)
    }

    func testMaskedSuffixAndVpaResolveConfirmedOwnedAliasesWithLiveAccount() throws {
        let database = try AppDatabase(inMemory: true)
        let context = database.container.mainContext
        let suffixAccount = Account(
            name: "A/c XX1234",
            bank: "Synthetic Bank",
            kind: .account,
            suffix: "1234"
        )
        let vpaAccount = Account(
            name: "UPI Primary",
            bank: "Synthetic Bank",
            kind: .account,
            suffix: nil
        )
        context.insert(suffixAccount)
        context.insert(vpaAccount)
        context.insert(
            SmsAccountAlias(
                accountID: suffixAccount.id,
                normalizedAliasHash: CanonicalJSON.sha256("suffix:1234"),
                aliasKind: "suffix",
                matchingScope: "owned_account_v1",
                confirmedByUser: true
            )
        )
        context.insert(
            SmsAccountAlias(
                accountID: vpaAccount.id,
                normalizedAliasHash: CanonicalJSON.sha256("vpa:user.name@synthbank"),
                aliasKind: "vpa",
                matchingScope: "owned_account_v1",
                confirmedByUser: true
            )
        )
        try context.save()

        let resolver = GroundedAccountResolver(context: context)
        XCTAssertEqual(
            try resolver.resolve(" account **１２３４ "),
            .unique(accountID: suffixAccount.id)
        )
        XCTAssertEqual(
            try resolver.resolve(" USER.Name@SynthBank "),
            .unique(accountID: vpaAccount.id)
        )
    }

    func testUnconfirmedWrongScopeDanglingAndMultiNumberAliasesStayUnresolved() throws {
        let database = try AppDatabase(inMemory: true)
        let context = database.container.mainContext
        let account = Account(
            name: "A/c XX4321",
            bank: "Synthetic Bank",
            kind: .account,
            suffix: "4321"
        )
        context.insert(account)
        context.insert(
            SmsAccountAlias(
                accountID: account.id,
                normalizedAliasHash: CanonicalJSON.sha256("suffix:4321"),
                aliasKind: "suffix",
                matchingScope: "owned_account_v1",
                confirmedByUser: false
            )
        )
        context.insert(
            SmsAccountAlias(
                accountID: account.id,
                normalizedAliasHash: CanonicalJSON.sha256("suffix:5555"),
                aliasKind: "suffix",
                matchingScope: "untrusted_scope",
                confirmedByUser: true
            )
        )
        context.insert(
            SmsAccountAlias(
                accountID: UUID(),
                normalizedAliasHash: CanonicalJSON.sha256("suffix:6666"),
                aliasKind: "suffix",
                matchingScope: "owned_account_v1",
                confirmedByUser: true
            )
        )
        try context.save()

        let resolver = GroundedAccountResolver(context: context)
        XCTAssertEqual(try resolver.resolve("**4321"), .unresolved)
        XCTAssertEqual(try resolver.resolve("**5555"), .unresolved)
        XCTAssertEqual(try resolver.resolve("**6666"), .unresolved)
        XCTAssertEqual(try resolver.resolve("accounts **1234 and **5678"), .unresolved)
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
                )
            )
        }
        try context.save()

        let resolution = try GroundedAccountResolver(context: context).resolve("**1234")

        guard case .ambiguous(let accountIDs) = resolution else {
            return XCTFail("Expected an account-integrity ambiguity")
        }
        XCTAssertEqual(Set(accountIDs), Set(accounts.map(\.id)))
    }
}
