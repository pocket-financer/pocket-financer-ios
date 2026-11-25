# Privacy and Security

## Local-only data boundary

Pocket Financer contains no remote inference client, network client, analytics SDK, ad SDK, CloudKit sync entitlement, or third-party Swift package dependency. CI enforces the absence of remote SPM packages and `CloudKit`, `Network`, and `URLSession` references in the app target (`PocketFinancer/`).

On-device inference runs exclusively through Apple's system language model (`SystemLanguageModel.default`). Automated unit tests use deterministic mock extractors and synthetic fixtures (`PocketFinancerTests/Fixtures/prefilter-vectors.json`).

## Storage protection

SwiftData files live inside an Application Support subdirectory (`PocketFinancer/PocketFinancer.store` plus `-wal`, `-shm`, and `.admission-lock` sidecars) configured by `SecureStoreFilePolicy`:

- `FileProtectionType.completeUntilFirstUserAuthentication` (`NSFileProtectionCompleteUntilFirstUserAuthentication`), allowing user-approved Shortcuts automations to save alerts while the device is locked after first unlock.
- `isExcludedFromBackup = true` on the store directory and every sidecar file so financial alerts never enter iCloud or iTunes/Finder backups.
- `PrivacyShieldView` obscures active app content whenever `scenePhase != .active` so sensitive balances and alerts do not appear in the iOS app switcher snapshot.

## Evidence lifecycle, duplicates, and tombstones

- **Retained evidence:** Alerts awaiting processing, retained in `SmsReviewCase`, or linked to a `Transaction` keep `InboxAlert.rawBody` locally for Review span selection, auditing, and retries.
- **Prefilter tombstones (`tombstoned_excluded`):** Unambiguous non-financial messages excluded by `SmsPrefilter` settle immediately without invoking the model, erasing `InboxAlert` sensitive fields (`rawBody = ""`, `sender = ""`, `sourceIdentity = "erased:<uuid>"`).
- **Extractor `none` tombstones (`tombstoned_none`):** Valid `none` decisions erase `InboxAlert` sensitive fields and redact `SmsProcessingAnalysis.canonicalJSON` and `SmsSelectorAttempt.requestJSON` to `"{}"`.
- **Short-window acquisition deduplication (15 seconds):** Identical normalized bodies arriving within 15 seconds (independent of sender and line-ending/Unicode normalization) are linked via `duplicateOfAlertID` and marked for review rather than creating duplicate transactions.
- **Semantic duplicate window (5 minutes / `300` seconds):** Matching `(accountID, direction, minorUnits, currency)` against a persisted transaction within `300` seconds routes to Review (`duplicate_possible`) instead of auto-saving.

## Fail-closed store recovery

If the store fails file-protection verification, cannot be opened, or was created by an unrecognized or newer schema outside `PocketFinancerSchemaV1`..`V7`, Pocket Financer:

1. Leaves all existing store files untouched on disk.
2. Pauses UI access and Shortcuts imports (`ImportTransactionAlertIntentError.localStoreUnavailable`).
3. Presents `LocalStoreUnavailableView` with sanitized diagnostic codes (`safeCode` and `diagnosticCode` that never expose file paths or message text) and a **Retry Local Store** action.

## Scoped local erasure

**Settings → Erase All Local Data** (`LocalDataService.eraseAll()`) requires explicit confirmation, increments `AlertIngestionService` processing epoch to invalidate any in-flight claims, and deletes all 20 SwiftData model types (transactions, accounts, aliases, alerts, operations, analyses, attempts, traces, results, gate decisions, review cases, feedback events, revisions, legacy snapshots, import receipts, contract release state, and historical V1–V4 audit records). Uninstalling the app removes the entire local container.

## Privacy verification checklist

- No log, error description, diagnostic string, or Shortcuts dialog interpolates alert bodies, senders, account references, or transactions.
- No network, cloud, or third-party runtime dependency exists in `PocketFinancer/` or `PocketFinancer.xcodeproj`.
- Both tombstone paths (`tombstoned_excluded`, `tombstoned_none`) clear `InboxAlert.rawBody` and redact stored analysis/request text.
- No real personal SMS, phone numbers, account identifiers, or signing credentials appear in source, tests, fixtures, docs, logs, or CI artifacts.

For vulnerability reporting instructions, see [SECURITY.md](../SECURITY.md).
