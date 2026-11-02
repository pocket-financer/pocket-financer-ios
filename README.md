# Pocket Financer — iOS

[![CI](https://img.shields.io/github/actions/workflow/status/ManishAradwad/pocket-financer-ios/ci.yml?branch=main&style=flat-square&logo=github)](https://github.com/ManishAradwad/pocket-financer-ios/actions/workflows/ci.yml)
[![Platform](https://img.shields.io/badge/Platform-iOS_26%2B-000000?style=flat-square&logo=apple&logoColor=white)](https://developer.apple.com/ios/)
[![Language](https://img.shields.io/badge/Language-Swift_6-F05138?style=flat-square&logo=swift&logoColor=white)](https://www.swift.org/)
[![UI](https://img.shields.io/badge/UI-SwiftUI-0D96F6?style=flat-square&logo=swift&logoColor=white)](https://developer.apple.com/xcode/swiftui/)
[![Intelligence](https://img.shields.io/badge/AI-Apple_Foundation_Models-34C759?style=flat-square&logo=apple&logoColor=white)](https://developer.apple.com/documentation/foundationmodels)

Pocket Financer is a private, local-first transaction tracker for iPhone. A
user-created Shortcuts automation can hand incoming financial alerts to the app,
which durably saves them, records advisory deterministic evidence, extracts
grounded transaction fields with Apple's on-device Foundation Models framework,
and stores review/ledger state with SwiftData.

Financial alerts, prompts, model output, and transactions are not sent to a Pocket Financer server. The app has no analytics SDK, ad SDK, network client, CloudKit transaction sync, or third-party runtime dependency.

> [!IMPORTANT]
> Automatic Message ingestion is an iOS 27 physical-device experiment until the complete Shortcuts payload and locked-device matrix passes on a real iPhone. Manual local import remains available. Historical SMS inbox access is intentionally out of scope because iOS provides no general SMS database API to apps.

> [!NOTE]
> The shared v4 direct-extractor integration is present in source but remains
> `review_only`. Complete valid v4 results still require owner review. Direct
> routing to Transactions is a planned additive contract change, not current
> behavior. See [SMS processing next steps](docs/sms-processing-next-steps.md).

## Current vertical slice

Pocket Financer currently implements the complete path from a matching financial SMS to a reviewable local transaction:

1. **Capture the alert:** You create a personal Message automation in Shortcuts and pass the message's `Content` to Pocket Financer's `Import Transaction Alert` action. Pocket Financer cannot browse your Messages inbox or import SMS history by itself.
2. **Save it before doing anything else:** The Shortcut stores the full alert in protected on-device storage and returns immediately; it does not wait for Apple's model. If overlapping `Rs`, `INR`, and `₹` automations deliver the same message within 15 seconds, Pocket Financer keeps one copy.
3. **Collect advisory evidence:** After onboarding, opening or returning to Pocket Financer starts work on its waiting inbox. Deterministic analysis records local cues and candidate spans, but it is not the semantic classifier or an answer allowlist.
4. **Extract transaction details on device:** Apple Foundation Models is the central classifier/extractor for the shared path. It returns `none`, `abstain`, or one posted event with exact Unicode-scalar evidence. The alert is not sent to a Pocket Financer server.
5. **Validate deterministically:** Model output is untrusted. Pocket Financer strictly parses it, grounds every span against the unchanged SMS, normalizes exact minor units, resolves an existing account, assesses duplicates, and preserves receipt time.
6. **Route by contract version:** Frozen v4 retains every posted result for owner review. A planned successor will send complete valid uniquely resolved non-duplicate results directly to Transactions and reserve Review for incomplete, invalid, ambiguous, abstained, interrupted, incompatible, or failed work.
7. **Review and correct the result:** Home shows this month's money in, money out, net cash flow, and recent activity. Transactions separates confirmed items from work that is waiting or needs review. You can inspect the original alert and processing history, correct and confirm a transaction, retry a saved alert, or manually import a synthetic test alert.
8. **See how each attempt was handled:** Protected local history records the rules applied, the request sent to Apple's model, the structured JSON snapshots the app was allowed to observe, the extracted draft, field-by-field validation, timing, and the accepted transaction snapshot. Later edits remain separate from that history. Apple does not expose hidden reasoning, token-level internals, or numeric confidence through this API.
9. **Keep the system local and recoverable:** The app has no analytics, ads, CloudKit transaction sync, Pocket Financer server, or third-party runtime dependency. Its database is excluded from backups, protected by iOS, and covered in the app switcher. If an existing store cannot be opened safely, Pocket Financer pauses access and preserves it for retry rather than deleting it or showing an empty replacement.

## How it works

```mermaid
flowchart LR
    A["Incoming financial SMS"] --> B["User-created Message automation"]
    B --> C["Import Transaction Alert App Intent"]
    C --> D["Durable SwiftData inbox write"]
    D --> E["Advisory deterministic analysis"]
    E --> G["Apple Foundation Models classifier/extractor"]
    G --> H["Strict parse + scalar/money/account/duplicate checks"]
    H --> I["Versioned routing"]
    I -->|"current v4"| J["Review"]
    I -.->|"planned complete-valid successor route"| K["Transactions"]
```

The model is never trusted as a database writer. The host owns grounding,
normalization, account resolution, persistence, and recovery.

## Processing transparency

Pocket Financer's transparency contract distinguishes seven concepts:

1. **Source evidence** is the locally retained alert body and optional sender metadata supplied by Shortcuts.
2. **Deterministic analysis** records advisory cues and any separately versioned
   privacy disposition; it is not the semantic answer.
3. **Observable generation** is the cumulative structured JSON exposed while Apple generates.
4. **Parser draft** is the mapped structured response produced by the system model before validation.
5. **Validation** checks every draft field against the source evidence and records a privacy-safe result code when the draft cannot be accepted.
6. **Accepted transaction** contains only evidence-validated values written
   atomically after the active route permits it; in v4 that requires owner
   confirmation because rollout is review-only.
7. **Owner correction** is an explicit later edit and must never be presented as the original model response.

The V4 SwiftData schema records the deterministic advisory analysis and creates
one protected attempt record for every live-ingestion or retry model attempt. It
captures the request, contract/profile identity, timing, observable cumulative
structured snapshots, strict parser result, validation stages, route, disposition,
and immutable accepted snapshot after confirmation. Failed or interrupted attempts
remain visible rather than being overwritten by a retry.

The live-ingestion adapter persists every cumulative raw structured JSON snapshot exposed by Apple's response stream, including the final raw response when it differs from the last streamed snapshot. It does not persist the session transcript, and Apple's iOS 26 API does not expose hidden reasoning, decoded token pieces/IDs, logits, or KV-cache internals. The processing screen shows these snapshots separately from the mapped draft and mutable current ledger transaction. Later owner edits do not rewrite historical generation, validation, or accepted snapshots, and an in-flight retry yields to any owner change made while it was running.

**Run Synthetic Model Test** opens a detailed report containing the exact synthetic input, instructions, request, checked model-processing locale, result of the locale support check, model-reported language identifiers, returned draft when available, validation result, safe failure, timing, configuration, and API limits. The report remains in memory, creates no transaction, and is released when its sheet is dismissed.

The public iOS 26 Foundation Models interface used by this build does not expose hidden reasoning, a stable owner-readable model build/version, per-request token counts or tokens per second, numeric context-window capacity, KV-cache details, or numeric confidence. It can report that a request exceeded its context window without revealing the window's size. Pocket Financer states those limitations instead of fabricating metrics. Exact prompts and persisted drafts are owner-visible local data only: they must never be copied into logs, telemetry, CI artifacts, source fixtures, screenshots, or issue reports. See [processing transparency](docs/processing-transparency.md) for the audit contract.

## Requirements

- macOS 26 or newer with Xcode 26 or newer.
- iOS 26 or newer for the app.
- A physical Apple Intelligence-capable iPhone for Foundation Models validation; current development targets iPhone 16.
- Apple Intelligence enabled with its on-device assets downloaded, and iPhone and Siri languages aligned to the same supported English language. The phone's Region may remain India.
- An Apple Development team for physical-device signing. A free Personal Team works for development installs.

This project is iPhone-only. The simulator is useful for UI, persistence, and deterministic tests, but a simulator availability result does not prove that Foundation Models assets can generate successfully.

## Local setup

1. Clone the repository and open `PocketFinancer.xcodeproj`.
2. Create `Config/Signing.local.xcconfig` with values unique to your Apple account:

   ```xcconfig
   DEVELOPMENT_TEAM = YOUR_TEAM_ID
   PRODUCT_BUNDLE_IDENTIFIER = your.reverse.dns.pocketfinancer.dev
   ```

   The file is optional and ignored by Git. Signing identities, provisioning profiles, and personal team values must never be committed.

3. Select the `PocketFinancer` scheme and an iPhone simulator or signed physical iPhone.
4. Build and run with Xcode.

The app has no package-resolution step.

If startup shows **Local store unavailable**, do not uninstall the app when its local data matters. Pocket Financer leaves the existing store untouched, pauses imports, displays a privacy-safe category/code, and offers **Retry Local Store**. It never auto-deletes, resets, replaces, or silently falls back to an empty in-memory store in production.

## Verification

Run the repository checks with the Xcode toolchain:

```sh
scripts/format.sh --lint
scripts/build.sh
scripts/test.sh
```

An unsigned Release build can also be run directly:

```sh
xcodebuild \
  -project PocketFinancer.xcodeproj \
  -scheme PocketFinancer \
  -configuration Release \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO \
  build
```

CI uses one simulator at a time and disables parallel test destinations to remain predictable on memory-constrained machines. Unit tests use injected parsers and never require Apple Intelligence or real financial alerts.

## Validate Foundation Models

On a freshly installed physical-device build:

1. Open Pocket Financer once and complete onboarding.
2. Open **Settings → Run Synthetic Model Test**.
3. Inspect the in-memory report's synthetic input, exact request, post-schema draft, validation result, safe failure information, timing, and explicit Apple API limits.
4. Record only the privacy-safe result category and latency outside the app. Do not screenshot or attach the detailed report to an issue.
5. Only proceed to live automation validation after the synthetic alert passes or its specific retryable failure is understood.

The app distinguishes model assets that are unavailable, unsupported language/locale, refusal or guardrail behavior, schema/decoding incompatibility, rate limiting, concurrent requests, timeout, and device eligibility. Its prompts and requested output are U.S. English, so it checks the explicit `en-US` model-processing locale with `supportsLocale`; the phone's `Locale.current` remains independent for India-region dates, numbers, and currency. This check is only a preflight because `LanguageModelSession` has no locale parameter and can still reject an unsupported input language during generation. Retryable failures remain durable, and any language failure retains evidence for manual review instead of creating a transaction.

## Configure the Message automation

Start with one `Message Contains debited` automation as a proof, then replace it with three sender-free currency automations for `Rs`, `INR`, and `₹`. Multiple Message conditions are combined as AND, not OR, so the three currency markers need separate automations.

The exact iOS 27 editor flow, input-variable mapping, automatic execution setting, and test procedure are documented in [Shortcuts setup](docs/shortcuts-setup.md). The resulting mapping is:

```text
When I receive a Message where Message Contains Rs
  → Import Transaction Alert
      Message Body = Shortcut Input → Content
      Sender = empty
      Received At = empty
      Source Application = empty
```

Pocket Financer uses the automation execution time when no message timestamp is available. False positives are expected at the trigger boundary and are rejected locally; normalized identical bodies delivered by overlapping currency automations are deduplicated for 15 seconds, independent of optional sender metadata.

## Project structure

```text
pocket-financer-ios/
├── Config/                    # Shared, target, version, and ignored local signing settings
├── PocketFinancer/
│   ├── App/                   # App lifecycle, root navigation, privacy shield
│   ├── Data/                  # SwiftData schema, database, file protection
│   ├── Domain/                # Filter, parsers, normalization, evidence validation
│   ├── Features/              # Onboarding, Home, Transactions, Settings
│   ├── Intents/               # Background-safe Shortcuts action
│   ├── Resources/             # Asset catalog and privacy manifest
│   └── Services/              # Ingestion, model adapter, retries, erasure, diagnostics
├── PocketFinancerTests/       # Deterministic unit, recovery, parity, and privacy tests
├── PocketFinancerUITests/     # Onboarding and settings smoke tests
├── docs/                      # Architecture, privacy, device, Shortcuts, and release guides
├── scripts/                   # Local build, format, and test entry points
└── .github/                   # CI, PR title, release, ownership, and dependency automation
```

## Privacy and security model

- Accepted alerts remain local as evidence so the owner can audit an extraction.
- Deterministically rejected OTP, verification, promotional, collect-request, and duplicate bodies are cleared.
- Model-only rejection is not trusted as proof of irrelevance; evidence remains available for owner review.
- The SwiftData store is excluded from backups and protected with `NSFileProtectionCompleteUntilFirstUserAuthentication`, allowing an approved automation to save after the first unlock.
- If the protected store cannot be opened or its schema is unsupported, access and imports pause while the original files remain in place for retry or recovery.
- **Erase All Local Data** invalidates in-flight processing and removes the ledger, accounts, queue, retained evidence, filter traces, generation snapshots, and extraction-run history. Uninstalling removes the complete app container.
- No real SMS corpus, phone number, account identifier, signing value, prompt transcript, or model response belongs in source control, CI artifacts, logs, screenshots, or issues.

Read [privacy and security](docs/privacy-and-security.md) before changing ingestion, persistence, inference, or diagnostics.

## Relationship to Android

The native Android companion is [`pocket-financer-android`](https://github.com/ManishAradwad/pocket-financer-android). Keep the repositories as sibling checkouts:

```text
Projects/
  pocket-financer-android/
  pocket-financer-intelligence/
  pocket-financer-ios/
```

The products share their canonical architecture, frozen contracts, sanitized
vectors, and evaluators through the sibling
[`pocket-financer-intelligence`](https://github.com/pocket-financer/pocket-financer-intelligence)
repository. They do not share UI/runtime code, raw SMS exports, private databases, or release
history. Do not use a submodule or copy Android implementation into this
repository.

## Development and releases

All implementation work uses a short-lived `codex/*` branch and a pull request targeting protected `main`. Pull-request titles follow Conventional Commits. Required checks cover formatting, an unsigned Release build, unit tests, UI smoke tests, and dependency/network-policy checks.

Release Please owns version and changelog updates. A merge to `main` may prepare a draft release pull request, but publication remains an explicit maintainer decision. See [CONTRIBUTING.md](CONTRIBUTING.md) and [releasing](docs/releasing.md).

## Roadmap

- [x] Native SwiftUI/SwiftData prototype and local privacy boundary.
- [x] Durable App Intent ingestion and sender-independent deterministic evidence.
- [x] Grounded Foundation Models extraction, diagnostics, retry, and synthetic test.
- [x] Owner-visible V4 pipeline history with exact filter decisions, cumulative structured-generation JSON, request/draft, per-field validation, immutable accepted snapshot, owner-edit separation, and explicit Apple API limits.
- [x] Detailed in-memory synthetic model report with exact synthetic request/draft, validation, safe failure, timing, and API limits.
- [x] Fail-closed local-store startup with safe recovery UI, paused imports, and preservation of unsupported pre-baseline data.
- [x] CI, UI smoke tests, draft release automation, and repository standards.
- [ ] Pass the physical iPhone 16 Foundation Models synthetic test on the current iOS 27 build.
- [ ] Prove `Shortcut Input → Content` and automatic execution while unlocked and locked.
- [ ] Implement and verify the additive exception-only-review routing contract:
  complete valid results to Transactions; only exception outcomes to Review.
- [ ] Execute the shared v4/successor parity evaluators on the Mac/Xcode lane.
- [ ] Refine visual identity, App Icon, accessibility, localization, charts, budgets, and insights.
- [ ] Complete App Store privacy, review, TestFlight, and distribution preparation.

## Copyright and usage

Copyright © 2026 Manish Aradwad. All rights reserved.

This repository is **not open source at this time**. No license is granted to use, modify, or redistribute its code or assets. The licensing model may be reconsidered in the future.

## Acknowledgments

- [Apple Foundation Models](https://developer.apple.com/documentation/foundationmodels) for private on-device language-model access.
- [App Intents](https://developer.apple.com/documentation/appintents) and [Shortcuts](https://support.apple.com/guide/shortcuts/welcome/ios) for the user-controlled ingestion boundary.
- [`pocket-financer-android`](https://github.com/ManishAradwad/pocket-financer-android) for the product semantics and cross-platform direction.
