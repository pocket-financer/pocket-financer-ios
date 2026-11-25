# Physical-device validation

Run these checks on a signed Apple Intelligence-capable iPhone before treating automatic Shortcuts ingestion as production-ready. Never record or share real message text, senders, prompts, or extracted values outside the device screen.

## Stable iOS 26 path

1. Install and launch Pocket Financer once; complete onboarding and confirm your primary currency.
2. Open **Settings -> Run Synthetic Model Test**. Confirm the diagnostic passes, shows `pocketfinancer.sms-extractor-input/1` and `DIRECT_NON_THINKING`, routes safely to Review, and leaves **Transactions** empty. Simulator builds cannot prove on-device generation quality.
3. In Shortcuts, create a personal Message automation with `Message Contains debited` for initial proof (no Sender condition), passing `Shortcut Input -> Content` to `Import Transaction Alert`. Choose **Run Immediately**.
4. Send a synthetic debit alert:
   - First time with an unrecognized masked suffix/VPA: confirm it opens `Review`, and confirming in `Review` creates both the `Transaction` and the confirmed `Account` / `SmsAccountAlias`.
   - Second time for the same linked account: confirm a valid `posted` alert outside the 5-minute duplicate window automatically saves directly into **Transactions** without creating an `SmsReviewCase`.
   - Within 5 minutes (`<= 300` seconds) for the same account, direction, amount, and currency: confirm the alert is retained in `Review` with `duplicate_possible`.
5. Send a synthetic OTP or non-financial message: confirm `SmsPrefilter` (`tombstoned_excluded`) or extractor `none` (`tombstoned_none`) discards it with an empty body and no transaction.
6. Replace the `debited` automation with separate sender-free automations for `Rs`, `INR`, and `₹`.
7. Test retryable failure recovery (Apple Intelligence off / force-quit during queue processing) and open **What Happened** (`AlertProcessingDetailView`) to inspect trace stages and store records.

## Store-recovery validation

Launch an isolated Debug build with `--ui-testing-store-unavailable` and verify **Local store unavailable** blocks UI and Shortcut imports without deleting or replacing existing store files. Remove the launch argument and relaunch to confirm clean recovery.

Separately verify `PocketFinancerSchemaMigrationTests` and `PocketFinancerV5MigrationTests` pass in Xcode CI so existing stores migrate forward safely.
