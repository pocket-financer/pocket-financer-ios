# Pocket Financer iOS contributor guidance

## Coordinated cleanup handoff

For cross-repository cleanup, first read the single shared
[cleanup plan](../pocket-financer-intelligence/docs/CLEANUP_PLAN.md) in the sibling
intelligence checkout. It records the owner's approved target, PR inventory,
preservation boundaries, and next task; do not duplicate it here. Its cleanup
target supersedes older product/roadmap choices, not privacy or Git/release
safeguards. Verify branches and PR state: useful implementation work is still on
unmerged feature branches, not necessarily the current checkout. If the plan is
absent, locate intelligence's `codex/docs-cleanup-handoff` branch before proceeding.

## Codex collaboration model profile

This repository currently uses the following Codex collaboration profile
(recorded 2026-08-31). It governs the coding agents working on this repository,
not the models shipped in the Pocket Financer app.

- The primary/root agent uses `gpt-5.6-sol` with `medium` reasoning. It owns
  scope, integration, and final verification.
- An `explorer` subagent uses `gpt-5.6-luna` with `medium` reasoning for
  read-only repository discovery and behavior tracing.
- A `worker` subagent uses `gpt-5.6-terra` with `medium` reasoning for bounded
  implementation and verification tasks.
- A `reviewer` subagent uses `gpt-5.6-terra` with `high` reasoning for read-only
  correctness, security, regression, and test review.
- A `default` subagent inherits the parent agent's model and reasoning effort
  unless the spawning task explicitly overrides them.

The active Codex runtime and task instructions are authoritative if this dated
profile differs from the live configuration. A model or reasoning override does
not change repository rules, task scope, permissions, or review requirements;
record any deliberate override in the task handoff.

## Product invariants

- Treat raw financial alerts as sensitive evidence. Persist an accepted alert before model work, keep processing local, and never log its body, sender, account label, or extracted transaction.
- No CloudKit, telemetry, ads, remote inference, or network dependency without an explicit product decision and privacy review.
- A model output is untrusted. Amount, date text, merchant, account label, and direction must be grounded in the raw alert before a transaction is saved.
- Deterministically rejected OTP, verification, promotional, and collect-request bodies must be erased immediately. A model-only rejection is untrusted and must retain evidence for review.
- Ingestion is idempotent and recovery-safe. A crash or unavailable model must leave a durable, retryable inbox record rather than lose evidence.
- Keep platform implementations native. Share semantics and sanitized fixtures with Android, not UI or runtime code.

## Development

- Minimum iOS version is 26. Use stable iOS 26 APIs for production behavior; isolate any iOS 27 experiment behind availability checks and never make prerelease APIs a shipping dependency.
- Use Swift 6 strict concurrency and Apple frameworks first. Avoid third-party dependencies unless the benefit is documented.
- Prefer standard SwiftUI containers and controls so the interface inherits current Liquid Glass behavior. Use explicit glass effects sparingly and only for interactive hierarchy.
- Keep the app usable when Foundation Models is unavailable: preserve eligible alerts as pending and support manual review/retry.
- Add or update unit tests for filtering, evidence validation, deduplication, persistence recovery, destructive erasure, and parser availability.
- Do not put real SMS messages, phone numbers, account identifiers, signing credentials, or model transcripts in source, fixtures, logs, screenshots, or CI artifacts.

## Git and releases

- Use Conventional Commit subjects (`feat:`, `fix:`, `docs:`, `test:`, `ci:`, `chore:`).
- All implementation work uses a short-lived `codex/<type>-<description>` branch and a pull request targeting `main`. Do not push feature, fix, refactor, documentation, dependency, or CI work directly to `main`.
- Codex should create the branch, commit, push, and open the pull request when repository credentials permit. Never bypass required checks or branch protection.
- Pull requests should remain focused and pass formatting, Release build, unit, and UI smoke checks. Pull-request titles use Conventional Commit form because the squash title becomes the commit on `main`.
- Release Please prepares releases; publishing remains an explicit maintainer action.
- Release Please owns `version.txt`, `CHANGELOG.md`, release tags, and stable GitHub Releases during normal operation. Do not merge its release pull request unless the user explicitly asks to publish.
- Never commit `xcuserdata`, signing material, local `.xcconfig` overrides, DerivedData, or `.xcresult` bundles.
