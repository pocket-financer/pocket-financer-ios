# Pocket Financer iOS contributor guidance

## Product invariants

- Treat raw financial alerts as sensitive evidence. Persist an accepted alert before model work, keep processing local, and never log its body, sender, account label, or extracted transaction.
- No cloud sync, telemetry, ads, remote inference, or network dependency without an explicit product decision and privacy review.
- `SmsPrefilter` (`sms-prefilter/1`) runs before model invocation using only the immutable SMS body and settles unambiguous non-financial alerts into body-free `tombstoned_excluded` records (`rawBody = ""`).
- Apple Foundation Models (`FoundationSmsExtractor` using the 18-field guided flat schema `apple-fm-flat.schema.json` and `prompts/apple-fm-sms-extractor.txt`) is the central classifier and extractor. Its output is untrusted: `SmsExtractorValidator` enforces one JSON object, Unicode-scalar spans, ISO-4217 currency markers, expanded direction cues, and normalized account/counterparty derivation.
- Receipt time is host-owned (`platform_received`) and never supplied or edited by the model or Review.
- Complete, strictly valid `posted` extractions that resolve to a unique confirmed `SmsAccountAlias` and clear the 5-minute (`300` seconds) duplicate window automatically save to `Transaction` and settle the `SmsProcessingOperation` as `.persisted`.
- Unresolved, ambiguous, abstained, invalid, failed, or 5-minute duplicate alerts retain source evidence and open a durable `SmsReviewCase`. Confirming or correcting in Review atomically saves the transaction and creates/links the confirmed `Account` and `SmsAccountAlias`.
- Valid `none` extractions erase sensitive evidence into body-free `tombstoned_none` tombstones (`rawBody = ""`).
- Ingestion is idempotent and recovery-safe. A crash or unavailable model preserves a durable retryable inbox record or review case rather than losing evidence.
- Keep platform implementations native. Share canonical contracts, assets (`sync_native_assets.py --target ios`), and sanitized fixtures with the sibling `pocket-financer-intelligence` and `pocket-financer-android` repositories without sharing UI or runtime code.

## Development

- Minimum iOS version is 26.0 with Swift 6 strict concurrency (`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`) and zero third-party packages.
- Read `.swift-format` before editing Swift files (`scripts/format.sh --lint` runs with `--strict`). Keep lines at or under 120 characters, keep imports lexicographically sorted, put one enum case per line, group numeric literals with five or more digits (`300_000`), and keep getters single-line where appropriate.
- Preserve existing `@Model` classes (`ExtractionRun`, `StructuredGenerationSnapshot`, `DeterministicFilterRun`, `InboxAlert`, `Transaction`, `Account`, and `SmsProcessingModels`) so consecutive `PocketFinancerSchemaV1..V7` migrations continue to pass.
- Do not commit real SMS messages, phone numbers, account identifiers, signing credentials, or model transcripts in source, fixtures, logs, screenshots, or CI artifacts.

## Git and releases

- Use Conventional Commit subjects (`feat:`, `fix:`, `docs:`, `test:`, `ci:`, `chore:`).
- Work on short-lived `codex/<type>-<description>` branches targeting `main`. Never push directly to `main`, and never commit `xcuserdata`, signing material, local `.xcconfig` overrides, `DerivedData`, or `.xcresult` bundles.
