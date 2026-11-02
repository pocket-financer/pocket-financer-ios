# Processing transparency

Pocket Financer provides owner-visible local audit without pretending that Apple's
private model internals are available. Its v4 path preserves the boundary between
source evidence, advisory deterministic analysis, observable structured
generation, untrusted model data, strict validation/routing, accepted ledger data,
and later human edits.

## Distinct records

| Stage | Meaning | V4 behavior |
| --- | --- | --- |
| Source evidence | Alert body, optional sender, origin, and receipt time supplied locally | Persisted in `InboxAlert` for eligible and model-only uncertain alerts; erased for deterministic rejection and duplicates |
| Deterministic analysis run | Exact advisory rule states evaluated before model work | Persisted in the versioned deterministic-run record, including rules version and any linked extraction-run ID; analyzer output is not the semantic answer |
| Structured generation snapshots | Cumulative `GeneratedContent.jsonString` values exposed by Apple's response stream before app mapping | Persisted in sequence on `StructuredGenerationSnapshot`; partial and final values remain explicitly labeled |
| Exact parser draft | `ParsedAlertDraft` fields returned after Apple's declared structured profile is mapped into Pocket Financer's schema | Persisted on the corresponding `ExtractionRun` before evidence validation; an explicit missing draft remains visible when no mapped response was returned |
| Validation | Per-field grounding of classification, direction, amount, account, and counterparty, plus host-owned receipt-time provenance | Every stage persists as passed, failed, or not run, together with the run's safe result code and terminal disposition; the model does not supply transaction time |
| Accepted transaction snapshot | Evidence-validated values at the moment the active route writes the ledger | Under review-only v4 this follows owner confirmation; persisted immutably with accepted evidence and absent when no transaction is written |
| Current ledger | The transaction currently used by the product | Stored separately in mutable `Transaction` and may be updated by a later successful retry while it remains unedited |
| Owner correction | Values intentionally changed after acceptance | Sets `isEdited`; retry never overwrites the owner's edit or changes historical run snapshots |

“Exact parser draft” has a deliberately narrow meaning. Foundation Models generates the declared guided profile, and Pocket Financer maps that value into `ParsedAlertDraft`. The live-ingestion adapter separately retains the exact cumulative raw structured JSON that Apple exposes through `ResponseStream.Snapshot.rawContent` and the final `Response.rawContent` when needed. It does not retain the session transcript. These observable JSON snapshots are not decoded token pieces, hidden reasoning, logits, KV-cache state, or an Apple-internal representation.

## Persistent attempt history

Every eligible ingestion or retry parser invocation appends one protected local `ExtractionRun` linked to its `InboxAlert`. The pipeline saves observable boundaries in order:

1. Before inference: the exact advisory-analysis record, then run ID, alert ID,
   attempt index, parser/contract/profile identity, the exact U.S. English
   model-processing locale identifier checked with `supportsLocale`, start time,
   exact instructions, and exact request. `Locale.current` remains separate for
   regional formatting.
2. During inference: each cumulative raw structured JSON snapshot exposed by Apple, saved before later validation or ledger mutation.
3. After a mapped response: response time and every `ParsedAlertDraft` field.
4. After validation: passed/failed/not-run state for classification, direction,
   amount, account, and counterparty, plus the host-owned receipt-time provenance.
5. At termination: completion time, safe result code, and imported/queued/needs-review disposition.
6. When accepted: immutable transaction ID, amount, currency, direction,
   counterparty, account, receipt-derived occurrence time, review state, and
   retained field evidence. Neither the model nor Review edits the receipt time.

Parser failures persist a run with no draft, validation marked not performed, and the safe failure/disposition. An interruption can leave an explicitly unfinished run at its latest saved boundary. Retrying appends another attempt instead of rewriting the earlier record.

The local **Processing Details** screen shows:

- durable alert status, origin, record ID, receipt/save/update times, and attempt count;
- privacy-safe alert-level error or rejection codes;
- every deterministic body-filter stage and the fact that sender does not affect eligibility;
- a disclosure for every persisted attempt containing its identity, timing, exact request, cumulative raw structured-generation snapshots, exact post-schema draft, validation stages, disposition, and immutable accepted snapshot;
- a separately labeled preview of the current app contract;
- a separately labeled mutable current saved transaction and owner-edit state;
- raw local source evidence when its retention policy permits it; and
- local retry controls for pending or reviewable evidence.

Historical runs are the source of truth for what a particular attempt used and produced. The current-contract preview can change with an app update, and the current ledger can change through a later retry or owner edit; neither rewrites a run.

## Synthetic self-test report

**Run Synthetic Model Test** exercises the same parser contract and evidence validator using a rewritten synthetic alert. Its detailed report includes:

- the exact synthetic body, sender metadata, and one receipt time shared by parsing and validation;
- parser, contract/profile version, exact checked model-processing locale, locale-support result, model-reported language identifiers, cancellation threshold, scheduling, guardrails, start/completion time, and elapsed wall-clock time;
- exact instructions and request;
- every returned post-schema `ParsedAlertDraft` field, or an explicit no-draft state;
- validation outcome, safe code, explanation, and validated fields when successful;
- retryability and owner-readable safe failure when unsuccessful; and
- every Apple API limitation listed below.

The result is intentionally in memory only. It creates no transaction or persistent `ExtractionRun`, is not logged or transmitted, and is released from Settings when the report sheet is dismissed.

## Schema and lifecycle

`PocketFinancerSchemaV2` adds `ExtractionRun`, V3 adds `StructuredGenerationSnapshot`, and V4 adds `DeterministicFilterRun` through consecutive lightweight migrations. Existing alerts, accounts, transactions, extraction runs, and V3 generation snapshots are preserved. Older records start with no evidence that their earlier app versions never captured, because the app cannot truthfully reconstruct historical requests, drafts, generation snapshots, or filter decisions.

Filter runs, generation snapshots, and extraction runs share the protected SwiftData store's backup exclusion and file-protection policy. **Erase All Local Data** first invalidates active processing claims, then deletes all pipeline evidence before transactions, accounts, and inbox alerts so a suspended response cannot write data back afterward. Uninstall removes the complete app container.

If an unsupported pre-baseline or newer-version store cannot enter the V1-to-V4 path, Pocket Financer preserves it and pauses the app instead of attempting to fabricate or discard audit history. The same fail-closed behavior applies when protected data, store opening, or file-protection verification fails. Production never auto-deletes the store or substitutes an empty in-memory container; the owner receives a safe category/code and an explicit retry action.

## Apple API limits

Apple Foundation Models does not expose the following through the API used by Pocket Financer:

- hidden reasoning or chain-of-thought;
- a stable owner-readable model build or version;
- per-request input/output token counts or tokens per second;
- numeric context-window capacity, even though the API can report that a request exceeded it;
- KV-cache contents, hit rate, or memory statistics; or
- numeric confidence, logits, or field-level probabilities.

Pocket Financer shows these as **not exposed by the public iOS 26 interface used by this build**. It does not derive a supposed confidence from validation, infer throughput from elapsed time, use a hard-coded marketing/model name as a build identifier, infer a context size from failures, or display reconstructed text as hidden reasoning. The public `supportedLanguages` identifiers and `supportsLocale` result are shown separately because those values are available.

Real-time transparency therefore means displaying each cumulative structured
snapshot as Apple exposes it. It does not mean token decoding on iOS. The UI must
state that decoded token pieces/IDs are unavailable and must never reconstruct
text and label it as tokens.

## Sensitive-data handling

Exact prompts, requests, drafts, evidence, sender/account identifiers, audit snapshots, and saved values are for the owner's local screen only. They must never enter application or OS logs, telemetry, analytics, crash payloads, notifications, source control, test fixtures, CI artifacts, screenshots, or issue reports. UI tests and documentation use rewritten synthetic values only.

Privacy-safe status codes and timing may be used for diagnostics when they contain no raw or derived financial value. The application provides no export/share action for sensitive processing details.
