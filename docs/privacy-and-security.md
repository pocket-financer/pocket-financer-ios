# Privacy and security

## Local-only data flow

Pocket Financer contains no remote inference client, network client, analytics SDK, ad SDK, or cloud sync entitlement. Foundation Models inference runs through Apple's on-device system model (`SystemLanguageModel.default`). Automated unit tests inject deterministic extractors and offline fixtures (`prefilter-vectors.json`).

SwiftData storage lives in an Application Support subdirectory excluded from device backups with `NSFileProtectionCompleteUntilFirstUserAuthentication` so background Shortcuts deliveries succeed after first unlock.

## Evidence lifecycle and tombstones

- Alerts awaiting processing or retained in `SmsReviewCase` keep `InboxAlert.rawBody` locally for confirmation, span selection, and retries.
- Unambiguous non-financial messages excluded by `SmsPrefilter` settle immediately with `retentionState = "tombstoned_excluded"` and `rawBody = ""` without invoking the model.
- Valid `none` decisions from `FoundationSmsExtractor` erase `InboxAlert.rawBody` (`""`) and redact stored analysis/request text into body-free `tombstoned_none` tombstones.
- Exact acquisition duplicates within 15 seconds are linked without creating a second transaction; 5-minute (`300` seconds) semantic duplicates (`accountId`, `direction`, `minorUnits`, `currency`) route to Review (`duplicate_possible`) rather than auto-saving.
- **Erase All Local Data** invalidates active claims and removes `SmsContractReleaseState`, pipeline traces, revisions, transactions, accounts, and alerts. Uninstall removes the complete container.

## Fail-closed store recovery

If a store fails file-protection verification, cannot be opened, or exceeds supported schema bounds (`PocketFinancerSchemaV1..V7`), Pocket Financer leaves the files untouched, pauses imports, and presents recovery UI instead of resetting or creating an empty replacement store.

## Checklist

- No logs interpolate alert bodies, senders, account references, or transactions.
- No network or cloud entitlements exist in the app target or manifests.
- All tombstones (`tombstoned_excluded`, `tombstoned_none`) clear raw SMS bodies cleanly.
- No real personal SMS, phone numbers, account identifiers, or signing secrets enter fixtures, docs, logs, or commits.
