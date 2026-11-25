# Processing transparency

Pocket Financer records owner-visible local audit state without claiming unavailable Apple
private model internals. The consolidated pipeline (`pocketfinancer.sms-pipeline/1`)
separates source admission, deterministic prefiltering, advisory structural analysis,
untrusted flat guided model extraction, host validation, duplicate/account checks,
settlement, and later owner edits.

## Distinct records

| Stage | Storage / Contract | Behavior |
| --- | --- | --- |
| Source admission | `InboxAlert` + `SmsSourceMetadataEvent` | Retained while pending/processing/review/imported; body erased (`""`) into `tombstoned_excluded` / `tombstoned_none` on terminal discard |
| Prefilter | `SmsPrefilter` (`sms-prefilter/1`) | Body-only exclusion before inference for empty, digit-less, promo, OTP, collect/mandate, telecom, brokerage EOD, and non-financial texts |
| Advisory analysis | `SmsProcessingAnalysis` | Deterministic clauses/candidates supplied to model as advice (never allowlist); redacted on `.none` tombstone |
| Model attempt | `SmsSelectorAttempt` | Stores request JSON, completion status, safe error code, and raw projected output JSON; redacted on `.none` tombstone |
| Normalized result & gate | `SmsReconstructedResult` & `SmsPersistenceDecision` | Stores `pocketfinancer.processing-result/3` JSON and checks (`rollout_mode: "automatic"`, `duplicate_assessment`, `account_resolution`) |
| Ledger & revisions | `Transaction` & `SmsTransactionRevision` | Written atomically on automatic save (`automatic_grounded_extraction`) or Review confirmation (`SmsUserFeedbackEvent` chain) |

## What Happened screen (`AlertProcessingDetailView`)

- Shows outcome card, tombstone `retentionState` when discarded, linked `Transaction` and `Account` records, `DecisionTraceTimeline`, `SmsPersistenceDecision`, source evidence (or body-erased tombstone notice), verified `SmsContractAssets.extractorPrompt()`, `SmsSelectorAttempt` request/response, retry action, and iOS 26 Apple API limits.

## Synthetic self-test report (`ModelSelfTestService`)

- Exercises `SmsOperationSnapshotFactory` and `SmsProcessingCoordinator` in memory with a synthetic alert (`Rs`/`INR` 500.00 debit at Demo Store) and `.unresolved` account resolver so it verifies prompt loading, locale check, guided generation, and strict validation while routing safely to Review without creating ledger transactions.

## Apple API limits

Apple Foundation Models does not expose hidden reasoning, a stable owner-readable model build, per-request token counts or tokens per second, numeric context-window size, KV-cache state, or numeric confidence/logits. Pocket Financer reports these metrics as unavailable rather than estimating them.
