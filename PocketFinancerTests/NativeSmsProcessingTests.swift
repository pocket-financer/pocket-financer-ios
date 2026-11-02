import SwiftData
import XCTest

@testable import PocketFinancer

private struct FixedDirectSelector: DirectCandidateSelecting {
    let rawOutput: String

    func select(source _: String, analysis _: SmsAnalysis) async throws -> DirectSelectorResponse {
        DirectSelectorResponse(
            rawOutput: rawOutput,
            runtimeProfileJSON: #"{"generation_mode":"DIRECT_NON_THINKING"}"#,
            requestJSON: #"{"contract":"pocketfinancer.grounded-candidate-selector-input/1"}"#,
            completion: "complete"
        )
    }
}

@MainActor
final class NativeSmsProcessingTests: XCTestCase {
    func testNativeSmsV4BundleUsesSuccessorConfigWithoutModelFileHash() throws {
        let binding = try NativeSmsV4Assets.verify()
        XCTAssertEqual(binding.releaseID, "native-integration-v4")
        XCTAssertEqual(binding.manifestSHA256, NativeSmsV4Assets.manifestSHA256)
        XCTAssertEqual(binding.artifactsByContract.count, 44)
        XCTAssertEqual(
            binding.artifactsByContract["pocketfinancer.processing-config/4"]?.sha256,
            NativeSmsV4Assets.processingConfigSHA256
        )
        let extractorSchema = try XCTUnwrap(
            binding.artifactsByContract["pocketfinancer.processing-config/4"]
        )
        XCTAssertEqual(
            extractorSchema.path,
            "configs/sms_processing/contracts/v4/processing-config.schema.json"
        )
        let configuration = SmsV4OperationConfiguration(
            operationID: UUID(), parentOperationID: nil, sourceID: UUID(),
            trigger: "diagnostic", primaryCurrency: "INR",
            enabledProfiles: ["core-en", "india"],
            receivedAt: TestFixtures.receivedAt,
            admissionAt: TestFixtures.receivedAt,
            timezoneID: "UTC", binding: binding,
            extractorEligible: true, createdAt: TestFixtures.receivedAt
        )
        let payload = try configuration.payloadJSON()
        let hash = CanonicalJSON.sha256(payload)
        let document = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Data((try configuration.documentJSON(configHash: hash)).utf8)
            ) as? [String: Any])
        let extractor = try XCTUnwrap(document["extractor"] as? [String: Any])
        XCTAssertTrue(document["parent_operation_id"] is NSNull)
        XCTAssertTrue(extractor["ineligibility_reason"] is NSNull)
        XCTAssertEqual(extractor["model_identity_kind"] as? String, "system_managed_runtime")
        XCTAssertTrue(extractor["model_file_sha256"] is NSNull)
        XCTAssertEqual(document["config_hash"] as? String, hash)
    }

    func testNativeSmsV3BundleRetainsManifestPathsAndBytes() throws {
        let binding = try NativeSmsV3Assets.verify()

        XCTAssertEqual(binding.releaseID, NativeSmsV3Assets.releaseID)
        XCTAssertEqual(binding.manifestSHA256, NativeSmsV3Assets.manifestSHA256)
        XCTAssertEqual(
            NativeSmsV3AssetIntegrityError.reasonCode,
            "configuration_integrity"
        )
        XCTAssertEqual(
            binding.artifactsByContract.count,
            NativeSmsV3Assets.expectedArtifactCount
        )
        XCTAssertEqual(
            binding.artifactsByContract["pocketfinancer.sms-extractor/1"]?.path,
            "configs/sms_processing/contracts/v3/sms-extractor.schema.json"
        )
        XCTAssertEqual(
            binding.artifactsByContract[
                "pocketfinancer.sanitized-extractor-golden/1"
            ]?.path,
            "tests/sms_processing/golden/extractor-v1/sanitized-vectors.json"
        )
    }

    func testCurrentSelectorConfigurationHasNoWallClockDeadline() {
        let configuration = SmsOperationConfiguration(
            operationID: UUID(),
            sourceID: UUID(),
            trigger: "diagnostic",
            createdAt: TestFixtures.receivedAt,
            primaryCurrency: "INR",
            enabledProfiles: ["core-en", "india"],
            sourceTimestamp: TestFixtures.receivedAt,
            sourceTimestampProvenance: "acquisition_supplied_message_time",
            admissionTimestamp: TestFixtures.receivedAt,
            timezoneIdentifier: "UTC",
            selectorModelIdentifier: "test-selector",
            selectorRuntimeVersion: "test-runtime"
        )

        XCTAssertEqual(configuration.contract, "pocketfinancer.processing-config/2")
        XCTAssertEqual(configuration.releaseID, "native-integration-v2")
        XCTAssertEqual(
            configuration.validationProfile,
            "pocketfinancer.selector-validation-profile/3"
        )
        XCTAssertEqual(configuration.parserDeadlineMilliseconds, 0)
    }
    func testPrimaryCurrencyRequiresExplicitConfirmation() {
        let defaults = UserDefaults.standard
        let previousCode = defaults.object(forKey: PrimaryCurrencySettings.key)
        let previousConfirmation = defaults.object(
            forKey: PrimaryCurrencySettings.confirmationKey
        )
        defer {
            defaults.removeObject(forKey: PrimaryCurrencySettings.key)
            defaults.removeObject(forKey: PrimaryCurrencySettings.confirmationKey)
            if let previousCode {
                defaults.set(previousCode, forKey: PrimaryCurrencySettings.key)
            }
            if let previousConfirmation {
                defaults.set(
                    previousConfirmation,
                    forKey: PrimaryCurrencySettings.confirmationKey
                )
            }
        }
        defaults.removeObject(forKey: PrimaryCurrencySettings.key)
        defaults.removeObject(forKey: PrimaryCurrencySettings.confirmationKey)
        defaults.set("USD", forKey: PrimaryCurrencySettings.key)

        XCTAssertNil(PrimaryCurrencySettings.confirmedCode)
        XCTAssertEqual(PrimaryCurrencySettings.currentCode, "USD")

        PrimaryCurrencySettings.confirm("USD")

        XCTAssertEqual(PrimaryCurrencySettings.confirmedCode, "USD")
        XCTAssertEqual(PrimaryCurrencySettings.enabledProfiles, ["core-en"])
    }

    func testAllFrozenAnalyzerAndTriageVectorsMatchCandidateIDsAndReasons() throws {
        let url = try XCTUnwrap(
            Bundle.main.url(forResource: "golden-parity-v1", withExtension: "json")
        )
        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
        let vectors = try XCTUnwrap(root["vectors"] as? [[String: Any]])
        XCTAssertFalse(vectors.isEmpty)
        for vector in vectors {
            let id = try XCTUnwrap(vector["id"] as? String)
            let source = try XCTUnwrap(vector["source"] as? String)
            let operationID = try XCTUnwrap(
                UUID(uuidString: try XCTUnwrap(vector["operation_id"] as? String))
            )
            let expectedJSON = try XCTUnwrap(vector["expected_analysis_json"] as? String)
            let expected = try XCTUnwrap(
                JSONSerialization.jsonObject(with: Data(expectedJSON.utf8)) as? [String: Any]
            )
            let expectedCandidates = try XCTUnwrap(expected["candidates"] as? [[String: Any]])
            let configuration = SmsOperationConfiguration(
                operationID: operationID,
                sourceID: UUID(),
                trigger: "diagnostic",
                createdAt: TestFixtures.receivedAt,
                primaryCurrency: "INR",
                enabledProfiles: ["core-en", "india"],
                sourceTimestamp: Date(timeIntervalSince1970: 1_700_000_000),
                sourceTimestampProvenance: "acquisition_supplied_message_time",
                admissionTimestamp: TestFixtures.receivedAt,
                timezoneIdentifier: "UTC",
                selectorModelIdentifier: "test-selector",
                selectorRuntimeVersion: "test-runtime"
            )
            let snapshot = SmsOperationSnapshot(
                operationID: operationID,
                parentOperationID: nil,
                stableEventID: UUID(),
                configuration: configuration,
                configurationJSON: "{}",
                configurationHash: try XCTUnwrap(vector["operation_config_hash"] as? String)
            )
            let actual = try StructuralSmsAnalyzer().analyze(source: source, operation: snapshot)
            XCTAssertEqual(try actual.canonicalJSON, expectedJSON, id)
            XCTAssertEqual(
                try FoundationDirectCandidateSelector.requestJSON(
                    source: source, analysis: actual
                ),
                vector["expected_selector_input_json"] as? String,
                id
            )
            XCTAssertEqual(actual.analysisID, expected["analysis_id"] as? String, id)
            XCTAssertEqual(
                actual.candidates.map(\.id),
                expectedCandidates.compactMap { $0["candidate_id"] as? String },
                id
            )
            XCTAssertEqual(actual.reasonCodes, expected["reason_codes"] as? [String], id)
            let expectedTriage = try XCTUnwrap(vector["expected_triage"] as? [String: Any])
            let actualTriage = SmsTriageEvaluator().evaluate(actual)
            XCTAssertEqual(actualTriage.disposition.rawValue, expectedTriage["disposition"] as? String, id)
            XCTAssertEqual(actualTriage.selectorAction.rawValue, expectedTriage["selector_action"] as? String, id)
            XCTAssertEqual(actualTriage.reasonCodes, expectedTriage["reason_codes"] as? [String], id)
        }
    }

    func testUnicodeGoldenVectorPreservesCodePointAndUtf8OffsetsAndCandidateIDs() throws {
        let source = "ＩＮＲ １０ was credited to account **１２３４ from SYNTH FRIEND."
        let operationID = try XCTUnwrap(UUID(uuidString: "11111111-1111-4111-8111-111111111111"))
        let configuration = SmsOperationConfiguration(
            operationID: operationID,
            sourceID: UUID(),
            trigger: "diagnostic",
            createdAt: TestFixtures.receivedAt,
            primaryCurrency: "INR",
            enabledProfiles: ["core-en", "india"],
            sourceTimestamp: TestFixtures.receivedAt,
            sourceTimestampProvenance: "acquisition_supplied_message_time",
            admissionTimestamp: TestFixtures.receivedAt,
            timezoneIdentifier: "UTC",
            selectorModelIdentifier: "test-selector",
            selectorRuntimeVersion: "test-runtime"
        )
        let snapshot = SmsOperationSnapshot(
            operationID: operationID,
            parentOperationID: nil,
            stableEventID: UUID(),
            configuration: configuration,
            configurationJSON: "{}",
            configurationHash: String(repeating: "a", count: 64)
        )

        let analysis = try StructuralSmsAnalyzer().analyze(source: source, operation: snapshot)

        XCTAssertEqual(analysis.analysisID, "549bc32c755f4a2e2e2787cd")
        XCTAssertEqual(
            analysis.candidates.map(\.id),
            [
                "amt_4415d29511db", "dir_c50e7a2f848d", "acc_5d9856de7f22",
                "cp_9c3f30764525", "acc_13e84438cabe", "cp_39f97723fe39",
            ]
        )
        let amountEvidence = try XCTUnwrap(analysis.candidates.first?.evidence)
        XCTAssertEqual(amountEvidence.endCharacter, 6)
        XCTAssertEqual(amountEvidence.endUTF8, 16)
    }

    @MainActor
    func testAnalyzerUsesExactMinorUnitsAndBlocksExpectedRefund() async throws {
        let database = try AppDatabase(inMemory: true)
        let context = database.container.mainContext
        let alert = makeAlert(body: "Refund of INR 1,234.50 is expected tomorrow")
        context.insert(alert)
        try context.save()
        let snapshot = try makeSnapshot(context: context, alert: alert)

        let analysis = try StructuralSmsAnalyzer().analyze(source: alert.rawBody, operation: snapshot)

        XCTAssertEqual(analysis.candidates.first(where: { $0.kind == .amount })?.value["minor_units"], "123450")
        XCTAssertTrue(analysis.reasonCodes.contains("expected_refund_not_posted"))
        XCTAssertEqual(analysis.completedEventCount, 0)
        await Task.yield()
    }

    @MainActor
    func testStrictSelectorRejectsDuplicateKeysAndForeignCandidates() async throws {
        let database = try AppDatabase(inMemory: true)
        let context = database.container.mainContext
        let alert = makeAlert(body: "INR 10.00 was paid from account **1234 at CAFE")
        context.insert(alert)
        try context.save()
        let snapshot = try makeSnapshot(context: context, alert: alert)
        let analysis = try StructuralSmsAnalyzer().analyze(source: alert.rawBody, operation: snapshot)
        let validator = GroundedSelectorValidator()

        XCTAssertThrowsError(
            try validator.validate(
                rawOutput: #"{"decision":"none","decision":"posted"}"#,
                analysis: analysis
            )
        ) { error in
            XCTAssertEqual(error as? GroundedSelectorValidationError, .duplicateKey)
        }
        XCTAssertThrowsError(
            try validator.validate(
                rawOutput:
                    #"{"decision":"posted","amount":"foreign","direction":"foreign","account":"foreign","counterparty":"foreign"}"#,
                analysis: analysis
            )
        ) { error in
            XCTAssertEqual(error as? GroundedSelectorValidationError, .unknownCandidate)
        }
        await Task.yield()
    }

    @MainActor
    func testPersistenceGateRejectsTwoDirectionCandidatesInOneClause() async throws {
        let database = try AppDatabase(inMemory: true)
        let context = database.container.mainContext
        let alert = makeAlert(body: "INR 10.00 was paid from account **1234 at CAFE")
        context.insert(alert)
        try context.save()
        let snapshot = try makeSnapshot(context: context, alert: alert)
        let original = try StructuralSmsAnalyzer().analyze(
            source: alert.rawBody, operation: snapshot
        )
        let amount = try XCTUnwrap(original.candidates.first { $0.kind == .amount })
        let direction = try XCTUnwrap(original.candidates.first { $0.kind == .direction })
        let account = try XCTUnwrap(original.candidates.first { $0.kind == .account })
        let counterparty = try XCTUnwrap(original.candidates.first { $0.kind == .counterparty })
        let selection = GroundedSelectorResult(
            decision: .posted,
            posted: SelectorPostedSelection(
                amountCandidateID: amount.id,
                directionCandidateID: direction.id,
                accountCandidateID: account.id,
                counterpartyCandidateID: counterparty.id
            )
        )
        let transaction = try SemanticReconstructor().reconstruct(
            selection: selection, analysis: original, operation: snapshot
        )
        let duplicate = SmsCandidate(
            id: "dir_duplicate",
            kind: .direction,
            clauseID: direction.clauseID,
            evidence: direction.evidence,
            explicitlyAbsent: false,
            value: direction.value,
            context: direction.context
        )
        let ambiguous = SmsAnalysis(
            contract: original.contract,
            analysisID: original.analysisID,
            configurationHash: original.configurationHash,
            sourceHash: original.sourceHash,
            source: original.source,
            clauses: original.clauses,
            candidates: original.candidates + [duplicate],
            cues: original.cues,
            reasonCodes: original.reasonCodes,
            completedEventCount: 1,
            profileID: original.profileID,
            primaryCurrency: original.primaryCurrency,
            normalizedStructuralFingerprint: original.normalizedStructuralFingerprint,
            currencyContextHash: original.currencyContextHash,
            sourceTimestampEpochMilliseconds: original.sourceTimestampEpochMilliseconds,
            sourceTimestampProvenance: original.sourceTimestampProvenance,
            unicodeDatabaseVersion: original.unicodeDatabaseVersion,
            clauseAnnotations: original.clauseAnnotations
        )

        let decision = AutomaticPersistenceGate().evaluate(
            analysis: ambiguous,
            triage: SmsTriageDecision(
                disposition: .invoke,
                selectorAction: .runNormal,
                reasonCodes: ["invoke_grounded_single_event"]
            ),
            selection: selection,
            transaction: transaction,
            accountResolution: .unique(accountID: UUID()),
            operation: snapshot,
            claimOwnershipCurrent: true
        )

        XCTAssertEqual(decision.result, .multipleEvents)
        XCTAssertEqual(
            decision.checks.first { $0.check == "single_completed_event" }?.passed,
            false
        )
        await Task.yield()
    }

    @MainActor
    func testCoordinatorPersistsTraceAndRetainsPostedResultInShadowMode() async throws {
        let database = try AppDatabase(inMemory: true)
        let context = database.container.mainContext
        let alert = makeAlert(body: "INR 10.00 was paid from account **1234 at CAFE")
        context.insert(alert)
        try context.save()
        let snapshot = try makeSnapshot(context: context, alert: alert)
        let analysis = try StructuralSmsAnalyzer().analyze(source: alert.rawBody, operation: snapshot)
        let amount = try XCTUnwrap(analysis.candidates.first { $0.kind == .amount })
        let direction = try XCTUnwrap(analysis.candidates.first { $0.kind == .direction })
        let account = try XCTUnwrap(analysis.candidates.first { $0.kind == .account })
        let counterparty = try XCTUnwrap(analysis.candidates.first { $0.kind == .counterparty })
        let raw =
            #"{"account":"\#(account.id)","amount":"\#(amount.id)","counterparty":"\#(counterparty.id)","decision":"posted","direction":"\#(direction.id)"}"#
        let store = SmsProcessingStore(modelContainer: database.container)
        let coordinator = DefaultSmsProcessingCoordinator(
            store: store,
            selector: FixedDirectSelector(rawOutput: raw),
            accountResolver: { _ in .unique(accountID: UUID()) }
        )

        let outcome = await coordinator.process(
            source: AdmittedMessageRef(
                sourceID: alert.id,
                admissionReceiptID: alert.id,
                sourceDigest: CanonicalJSON.sha256(alert.rawBody)
            ),
            operation: snapshot,
            observer: NoOpSmsProcessingObserver()
        )

        guard case .retainedForReview(_, _, let reasons) = outcome else {
            return XCTFail("Expected shadow-mode review, got \(outcome)")
        }
        XCTAssertTrue(reasons.contains("persistence_blocked_by_rollout_mode"))
        let verification = ModelContext(database.container)
        XCTAssertEqual(try verification.fetch(FetchDescriptor<SmsProcessingAnalysis>()).count, 1)
        XCTAssertEqual(try verification.fetch(FetchDescriptor<SmsSelectorAttempt>()).count, 1)
        XCTAssertEqual(try verification.fetch(FetchDescriptor<SmsReconstructedResult>()).count, 1)
        let persistence = try XCTUnwrap(
            verification.fetch(FetchDescriptor<SmsPersistenceDecision>()).first
        )
        XCTAssertEqual(persistence.resultRawValue, "blocked_by_mode")
        XCTAssertEqual(persistence.primaryReason, "persistence_blocked_by_rollout_mode")
        let checks = try JSONDecoder().decode(
            [PersistenceGateCheck].self,
            from: Data(persistence.checksJSON.utf8)
        )
        XCTAssertEqual(checks.filter(\.passed).count, checks.count - 1)
        XCTAssertEqual(
            checks.first { !$0.passed }?.reasonCode,
            "persistence_blocked_by_rollout_mode"
        )
        XCTAssertFalse(try verification.fetch(FetchDescriptor<SmsProcessingTraceEvent>()).isEmpty)
        XCTAssertEqual(try verification.fetch(FetchDescriptor<SmsReviewCase>()).count, 1)
        XCTAssertTrue(try verification.fetch(FetchDescriptor<Transaction>()).isEmpty)
    }

    @MainActor
    private func makeSnapshot(context: ModelContext, alert: InboxAlert) throws -> SmsOperationSnapshot {
        try SmsOperationSnapshotFactory(context: context).create(
            sourceAlertID: alert.id,
            trigger: "test",
            primaryCurrency: "INR",
            enabledProfiles: ["core-en", "india"],
            selectorModelIdentifier: "test-selector",
            selectorRuntimeVersion: "test-runtime",
            now: TestFixtures.receivedAt
        )
    }

    @MainActor
    private func makeAlert(body: String) -> InboxAlert {
        InboxAlert(
            sourceIdentity: UUID().uuidString,
            contentDigest: CanonicalJSON.sha256(body),
            origin: .manual,
            sourceApplication: "Tests",
            sender: "SYNTH",
            rawBody: body,
            receivedAt: TestFixtures.receivedAt
        )
    }
}
