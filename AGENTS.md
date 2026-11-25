# Pocket Financer iOS — Agent & Contributor Guide

This file is the single source of truth for all coding agents and contributors working in `pocket-financer-ios`.

## Repository boundaries

- `pocket-financer-ios` owns the native iOS 26+ SwiftUI/SwiftData app, App Intents admission, Apple Foundation Models extractor transport, unit tests (`PocketFinancerTests`), and UI smoke tests (`PocketFinancerUITests`).
- [`pocket-financer-intelligence`](https://github.com/pocket-financer/pocket-financer-intelligence) is the canonical owner of shared SMS contracts, schemas, prompts, profiles, and golden vectors (`configs/sms_processing/`). Never hand-edit synced files under `PocketFinancer/Resources/SmsProcessing/` or `PocketFinancerTests/Fixtures/prefilter-vectors.json` without updating the canonical source and running `sync_native_assets.py --target ios`.
- [`pocket-financer-android`](https://github.com/pocket-financer/pocket-financer-android) implements the same `pocketfinancer.sms-pipeline/1` contract natively on Android; share contracts and synthetic fixtures only, never UI or runtime code.

## Product & pipeline invariants

- **Local-only runtime:** Zero remote inference, networking clients, CloudKit, analytics, ads, or third-party Swift packages. CI enforces the absence of `CloudKit`, `Network`, `URLSession`, and remote SPM references in `PocketFinancer/` and `project.pbxproj`.
- **Sensitive evidence handling:** Persist accepted alerts into protected SwiftData (`NSFileProtectionCompleteUntilFirstUserAuthentication`, excluded from backups) before model work. Never log raw alert bodies, senders, account labels, prompts, or extracted transactions.
- **Fail-open prefilter before inference:** `SmsPrefilter` (`sms-prefilter/1`) inspects only the immutable SMS body and settles unambiguous non-financial alerts into body-free `tombstoned_excluded` records (`rawBody = ""`).
- **Untrusted model output:** `FoundationSmsExtractor` runs Apple Foundation Models (`SystemLanguageModel.default`) with the 18-field guided flat schema (`schemas/apple-fm-flat.schema.json`) and `prompts/apple-fm-sms-extractor.txt`, projecting deterministically into `pocketfinancer.sms-extractor/1`. `SmsExtractorValidator` enforces a single JSON object (no duplicate keys, floats, or trailing data), Unicode-scalar spans, ISO-4217 currency markers, grounded debit/credit cues, exact `Int64` minor units, and normalized account/VPA and counterparty values.
- **Host-owned receipt time:** Receipt time (`platform_received`) is always host-owned and read-only; never let the model or grounded Review alter it.
- **Automatic save vs. Review vs. tombstones:**
  - Valid `posted` extractions that resolve to a unique confirmed `SmsAccountAlias` and clear the 5-minute (`300` seconds) duplicate window `(accountID, direction, minorUnits, currency)` automatically persist `Transaction`, `SmsTransactionRevision`, and `.persisted` operation state.
  - Unresolved, ambiguous, abstained, invalid, interrupted, failed, or 300-second duplicate alerts retain source evidence and open or update a durable `SmsReviewCase`. Confirming or correcting in Review atomically saves `Transaction` and links/creates the confirmed `Account` and `SmsAccountAlias`.
  - Valid `none` extractions erase sensitive evidence (`InboxAlert.rawBody = ""`, redacted analysis and attempt request JSON) into body-free `tombstoned_none` tombstones.
- **Idempotency & fail-closed recovery:** Ingestion, durable claims, review commands, and ledger edits are idempotent and crash-safe. Store startup failures leave existing database files untouched and pause imports instead of resetting or recreating an empty store.

## Engineering & style rules

- **Toolchain:** iOS 26.0 minimum deployment target, Swift 6 strict concurrency (`SWIFT_STRICT_CONCURRENCY = complete`, `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` on the app target), `SWIFT_UPCOMING_FEATURE_MEMBER_IMPORT_VISIBILITY = YES`, zero third-party packages.
- **Formatting (`.swift-format`):** `scripts/format.sh --lint` runs `xcrun swift-format lint --strict` across `PocketFinancer`, `PocketFinancerTests`, and `PocketFinancerUITests`. Always match:
  - 4-space indentation, Unix `LF` line endings, lines <= 120 characters, max 1 consecutive blank line.
  - Lexicographically sorted `import` declarations (explicitly import every module whose symbols or extensions are used).
  - One `enum` case and one variable declaration per line; group 5+ digit numeric literals (`300_000`); single-line property getters; no block comments (`/* */`); no semicolons; `for` loops instead of `.forEach`.
- **Xcode synchronized groups:** `PocketFinancer`, `PocketFinancerTests`, and `PocketFinancerUITests` all use `PBXFileSystemSynchronizedRootGroup` in `PocketFinancer.xcodeproj/project.pbxproj`. Adding, renaming, or deleting Swift files inside those folders updates the targets automatically without manual `pbxproj` edits.
- **Schema migrations:** Preserve all existing `@Model` definitions and `PocketFinancerSchemaV1`..`V7` history so `SchemaMigrationTests` passes across every consecutive version. Never invent missing historical audit fields during migration.
- **Synthetic data only:** Never commit real SMS bodies, phone numbers, account identifiers, signing credentials, local `.xcconfig` overrides, `xcuserdata`, `DerivedData`, or `.xcresult` bundles.

## Verification

Run before opening or updating a pull request (on macOS with Xcode 26+, or verify via GitHub Actions CI when editing from a non-macOS host):

```sh
scripts/format.sh --lint
scripts/build.sh
scripts/test.sh
python ../pocket-financer-intelligence/scripts/sync_native_assets.py --check --target ios
```

## Git, PRs & releases

- Work on short-lived branches named `<type>/<short-description>` (for example `feat/account-alias-picker`, `fix/duplicate-window`, `chore/overhaul-tests-docs-ci`) targeting `main`.
- Never commit or push directly to `main`, and never bypass required status checks (`Format, build, and test` and `Conventional Commit title`).
- Use Conventional Commit PR titles (`feat:`, `fix:`, `perf:`, `refactor:`, `revert:`, `test:`, `docs:`, `build:`, `ci:`, `chore:`); squash-merge turns the PR title into the commit on `main`.
- Never edit `CHANGELOG.md`, `version.txt`, `Config/Version.xcconfig`, or `.release-please-manifest.json` in ordinary pull requests—Release Please owns routine releases (see [docs/releasing.md](docs/releasing.md)).
