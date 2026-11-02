# Privacy and security

## Local-only data flow

The shipping app contains no network client, analytics SDK, ad SDK, CloudKit entitlement, or remote model integration. Foundation Models inference runs through Apple's on-device system model. CI tests inject a fake parser.

SwiftData is stored in an Application Support subdirectory that is excluded from device backups. Its directory and SQLite files use `NSFileProtectionCompleteUntilFirstUserAuthentication`, matching background Shortcuts execution after the first device unlock. This is a deliberate balance: `NSFileProtectionComplete` would make background ingestion fail whenever the phone is locked.

Protection is applied directly to the database directory and SQLite sidecar files rather than requested as an app-signing entitlement. This keeps Personal Team development provisioning compatible while preserving the required file-level policy.

## Evidence lifecycle

- Eligible alerts retain raw evidence locally so the owner can audit and correct extraction.
- Exact duplicates retain safe metadata but do not create another transaction.
- Shared transaction analysis is advisory and cannot by itself declare an alert
  irrelevant. Exact duplicates and narrowly versioned credential/privacy
  dispositions may clear evidence under their explicit retention policy; model
  uncertainty and review outcomes retain the source needed for owner review.
- Each filter evaluation creates a protected `DeterministicFilterRun`. Each eligible ingestion or retry model attempt creates a protected `ExtractionRun` and persists every cumulative raw structured JSON snapshot Apple exposes during live generation. The run also stores exact instructions/request, exact post-schema `ParsedAlertDraft` fields when returned, validation-stage outcomes, timing, safe code, disposition, and an immutable accepted-transaction snapshot when applicable.
- Erase All Data invalidates active processing before deleting filter runs, generation snapshots, extraction runs, transactions, accounts, and inbox evidence in one local operation. Suspended model work cannot repopulate the store afterward. Pocket Financer relies on iOS to reclaim deleted database pages safely; uninstalling the app removes its complete data container.
- The detailed synthetic self-test report uses rewritten test data, remains in memory, creates no transaction or `ExtractionRun`, and is released when the Settings sheet is dismissed.
- Exact model instructions, requests, drafts, and audit snapshots are visible only to the owner inside local app UI. They are not written to logs or telemetry.

## Transparency without disclosure

The transparency contract distinguishes the source alert, advisory deterministic
analysis, observable cumulative structured-generation JSON, untrusted parser
result, strict validation and routing, immutable accepted snapshot, current saved
transaction, and any later owner correction. An edited ledger entry is not
evidence of what the model originally produced. V4 preserves each captured
boundary without fabricating history for records created before that boundary
existed.

The public iOS 26 Foundation Models interface used by this build does not give the app hidden reasoning, a stable owner-readable model build/version, request token counts or tokens per second, numeric context-window capacity, KV-cache information, or numeric confidence. The app must label these values as unavailable and must not estimate or fabricate them. It may display the exact U.S. English model-processing locale checked with `supportsLocale`, the separate `Locale.current` formatting identifier, and identifiers returned by `supportedLanguages`, because those are public observable values.

Exact prompts, reconstructed requests, raw generation JSON, raw alerts, exact parser drafts, evidence spans, and transactions are sensitive local data. They must never be placed in application logs, telemetry, crash payloads, source control, CI artifacts, screenshots, or issue reports. Privacy-safe status/error codes and aggregate durations may be recorded for manual testing only when they contain no financial values or identifiers.

## Fail-closed store recovery

The production app never treats an unreadable database as permission to delete it or create an empty replacement. If the store is from an unsupported pre-baseline prototype, was created by a newer app version, is unavailable before protected data unlock, fails file-protection verification, or otherwise cannot be opened, Pocket Financer preserves the existing store files and pauses all UI and Shortcut imports.

The blocking recovery screen shows only a safe failure category and system domain/code, offers retry, and warns that uninstalling also deletes the preserved app container. There is no automatic migration guess, destructive reset, in-memory production fallback, or background import into a second store. Live ingestion fails internally with `storeUnavailable`; the App Intent converts it to a privacy-safe error that explicitly says the alert was not saved and must be run again after local-store recovery.

## Threat assumptions

File protection reduces offline access while the device is locked; it does not defend against a fully unlocked, compromised device. The app does not claim bank-grade custody, fraud detection, or accounting correctness. Users remain responsible for checking imported transactions against their statements.

## Review checklist

- Does any new log interpolate alert or transaction data?
- Does a new framework send data or add privacy-manifest declarations?
- Can cancellation or termination lose an accepted alert?
- Can a startup failure delete, replace, bypass, or write beside the existing protected store?
- Can model text reach storage without evidence validation?
- Does transparency clearly distinguish an exact parser draft from accepted data and later owner edits?
- If a new audit field is sensitive, is it protected, excluded from backup, erased with local data, and absent from logs, screenshots, crash payloads, CI, and issues?
- Does a rejected secret remain in any persisted property?
- Are destructive actions explicit, scoped, and tested?
