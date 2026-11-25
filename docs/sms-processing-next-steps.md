# iOS SMS processing status & next steps

Status: **consolidated on source; awaiting macOS/iPhone verification**

`pocket-financer-intelligence` owns the canonical SMS contracts, prompts, schemas, profiles, and golden vectors (`configs/sms_processing/`), synced into iOS via `scripts/sync_native_assets.py --target ios` into `PocketFinancer/Resources/SmsProcessing/` and `PocketFinancerTests/Fixtures/prefilter-vectors.json`.

## Implemented in source

- **Deterministic asset verification (`SmsContractAssets`)**: verifies `release-manifest.json` (`pocketfinancer.sms-pipeline/1`) and all 17 bundled iOS assets before creating operations or loading `prompts/apple-fm-sms-extractor.txt`.
- **Prefilter before inference (`SmsPrefilter`)**: mirrors `sms-prefilter/1` (`54/54` vectors) and settles exclusions into body-free `tombstoned_excluded` records.
- **Flat guided Apple Foundation Models extractor (`FoundationSmsExtractor`)**: generates 18-field `@Generable` `GeneratedSmsExtraction` matching `apple-fm-flat.schema.json` with deterministic canonical projection (`projectFlatExtraction`) into `pocketfinancer.sms-extractor/1`.
- **Host validator (`SmsExtractorValidator`)**: enforces Unicode-scalar spans, ISO-4217 currency markers, expanded debit/credit cues, normalized masked account/VPA references, and counterparty derivation.
- **Coordinator & Store (`SmsProcessingCoordinator`, `SmsProcessingStore`)**:
  - Automatic save (`rollout_mode: "automatic"`) when valid `posted` resolves uniquely to a confirmed `SmsAccountAlias` and clears the 5-minute (`300` seconds) duplicate window.
  - Review retention (`SmsReviewCase`) for unresolved, ambiguous, abstained, invalid, failed, or 300-second duplicate results, with atomic `Account` + confirmed `SmsAccountAlias` creation on confirmation.
  - Body-free tombstones (`tombstoned_excluded`, `tombstoned_none`) erasing `InboxAlert.rawBody`.

## Verification order on macOS / physical iPhone

1. Run `python ../pocket-financer-intelligence/scripts/sync_native_assets.py --check --target ios`.
2. Run `scripts/format.sh --lint`, `scripts/build.sh`, and `scripts/test.sh` (including `SmsPrefilterTests`, `FoundationSmsExtractorTests`, `PocketFinancerSchemaMigrationTests`, `NativeSmsProcessingTests`, `AlertIngestionServiceTests`, `SmsProcessingStoreTests`, and `ModelSelfTestServiceTests`).
3. Run the **Settings -> Run Synthetic Model Test** check on an Apple Intelligence-enabled iPhone and complete Shortcuts unlock/lock delivery checks in [device-validation.md](device-validation.md).
