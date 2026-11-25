# Physical-Device Validation

Run this checklist on a signed, Apple Intelligence-capable iPhone before treating automatic Shortcuts ingestion or on-device extraction as release-ready. Never record, screenshot, or share real message bodies, senders, prompts, or extracted values outside the device.

## Prerequisites

- Physical Apple Intelligence-capable iPhone running iOS 26+.
- iPhone and Siri languages aligned to supported English (`en-US` model check); iPhone Region may remain India.
- Local signing configured in ignored `Config/Signing.local.xcconfig` (`DEVELOPMENT_TEAM` and `PRODUCT_BUNDLE_IDENTIFIER`).

## Pipeline and Shortcuts matrix

1. **First run & currency:** Install and launch Pocket Financer once, complete onboarding, and confirm your primary currency.
2. **Synthetic model self-test:** Open **Settings → Run Synthetic Model Test**. Confirm it passes, reports `pocketfinancer.sms-extractor-input/1` and `DIRECT_NON_THINKING`, routes safely to Review, and leaves **Transactions** empty. (Simulator builds cannot verify Apple Foundation Models generation quality.)
3. **Initial Shortcuts proof:** Follow [shortcuts-setup.md](shortcuts-setup.md) to create a sender-free Message automation (`Message Contains → debited`, **Run Immediately**, passing `Shortcut Input → Content` to `Import Transaction Alert`).
4. **End-to-end transaction routing (synthetic alerts from another phone):**
   - **Unlinked account (first time):** Confirm the alert opens **Review** (`account_resolution_unresolved`), and confirming in **Review** atomically creates the `Transaction`, `Account`, and confirmed `SmsAccountAlias`.
   - **Linked account (outside 5 minutes):** Send a second valid `posted` alert for the same account more than 300 seconds later; confirm it auto-saves directly into **Transactions** without creating an `SmsReviewCase`.
   - **5-minute duplicate (`<= 300` seconds):** Send an identical-amount/direction alert for the same linked account within 300 seconds; confirm it routes to **Review** (`duplicate_possible`) instead of auto-saving.
5. **Tombstone privacy checks:**
   - Send a synthetic OTP or collect-request alert; confirm `SmsPrefilter` discards it as `tombstoned_excluded` with an empty body and no transaction.
   - Send a synthetic non-transaction balance/statement alert; confirm `FoundationSmsExtractor` `none` discards it as `tombstoned_none` with an empty body and redacted analysis/request JSON.
6. **Production-like triggers:** Replace the `debited` automation with separate sender-free automations for `Rs`, `INR`, and `₹`, and verify overlapping matches within 15 seconds coalesce cleanly.
7. **Locked-device & failure recovery:**
   - Lock the iPhone (after first unlock since reboot) and send a synthetic alert; confirm Shortcuts saves it without unlocking, and opening Pocket Financer processes the queued item.
   - Disable Apple Intelligence (or force-quit mid-drain), send a synthetic alert, re-enable Apple Intelligence, and open **What Happened** (`AlertProcessingDetailView`) to inspect `DecisionTraceTimeline`, stored attempt metadata, and retry behavior.

## Store-recovery and migration checks

1. Launch a Debug build with `--ui-testing-store-unavailable` and verify **Local store unavailable** blocks UI and Shortcut imports without deleting or replacing existing store files. Remove the launch argument and relaunch to confirm clean recovery.
2. Verify `SchemaMigrationTests` passes in Xcode / GitHub Actions CI so consecutive `PocketFinancerSchemaV1`..`V7` stores migrate forward without data loss.
