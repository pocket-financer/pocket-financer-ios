# iOS SMS processing next steps

Status: **platform handoff; not a completion claim**
Last reconciled: 2026-09-22

The shared repository `pocket-financer-intelligence` owns the canonical architecture,
versioned contracts, sanitized vectors, host GGUF evaluation, native-trace import,
and the planned Android/iOS native scoring lanes. This repository owns the
Swift/Foundation Models, SwiftData, SwiftUI, Xcode, simulator, and physical-iPhone
implementation lane.

## Implemented source baseline

The additive v4 source includes strict extractor parsing, Unicode-scalar conversion,
exact minor-unit normalization, account resolution, sanitized vectors, v4
operation routing, SwiftData migration, durable review/recovery state, review
drafts, atomic confirmation, full-source review, per-field highlights, and one
active native text selection. V1/v2/v3 stored operations remain compatible.

V4 is `review_only`. A complete valid result is therefore still retained for
review. Swift/XCTest source coverage is not a Mac build, simulator run, or iPhone
result. Those gates remain open.

## Next implementation change

After the shared repository freezes an additive successor contract:

1. Route a complete, strictly valid, uniquely resolved, non-duplicate posted result
   directly and atomically into Transactions.
2. Route only incomplete, invalid, ambiguous, abstained, interrupted,
   incompatible, or failed operations to Review.
3. Keep valid `none` handling separate from Transactions and Review according to
   the versioned evidence-retention policy.
4. Preserve original release routing for stored operations and create an explicit
   new operation for a retry under the successor release.
5. Keep corrections revision-bound, append-only, local label evidence. Explicit
   export and adjudication are required before approved, source-grounded,
   split-safe labels may improve the SLM or another pipeline component.

## Transparency and Apple API limits

Foundation Models exposes cumulative structured-generation snapshots, not decoded
token pieces/IDs, token counts, logits, hidden reasoning, or an app-readable model
file. Show each observable snapshot while generation is active and label token
decoding as unavailable. Never reconstruct text and call it tokens.

For model identity, use `system_managed_runtime` with
`model_file_sha256: null` and record the observable runtime, OS, device, prompt,
grammar, validation, and model identifier fields. Never fabricate a hash.

Re-run accessibility coverage for the complete source SMS, separate
amount/direction/account/counterparty highlights, VoiceOver labels and focus order,
and the single-active-selection invariant. A later failure must not hide fields
that were successfully grounded earlier: Review shows every valid partial field
from the last completed stage on the unchanged SMS body.

## Shared evaluation lane

`pocket-financer-intelligence` already provides the host GGUF evaluator and encrypted
native-trace import. The dedicated iOS native evaluator/scorer does not exist yet
and remains planned. It will run the exact app contract through the Mac/Xcode lane,
export a provenance-bound encrypted trace bundle, and score aggregate contract,
model, routing, review, recovery, latency, and resource results in the shared
repository. Host or Android evidence is not iOS Foundation Models evidence.

## Mac/iOS verification order

1. Verify the shared v4/successor bundle and sanitized vectors without modifying
   frozen assets.
2. Run Swift formatting, an unsigned Release build, XCTest, migrations, recovery,
   atomic confirmation, and UI/accessibility tests on Xcode.
3. Run simulator flows for UI, storage, migration, and process recovery; do not
   treat simulator model availability as Foundation Models generation evidence.
4. Run the supported physical iPhone matrix for the synthetic extractor,
   Foundation Models provenance, live snapshots, Shortcuts unlocked/locked
   delivery, interruption/retry, accessibility, memory, latency, thermal, and
   battery behavior.

Do not enable rollout or describe the full SMS implementation as complete until
the shared evaluation strategy and physical-device gates pass.
