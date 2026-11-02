# Physical-device validation

These checks cannot be proven by a simulator or CI. Run them on the signed iPhone 16 before calling automatic ingestion production-ready. Record the Xcode build, iOS build number, iPhone and Siri languages, the separate app-formatting and model-processing locale identifiers shown by Pocket Financer, the model-language identifiers, and the synthetic generation result without copying real message contents.

## Stable iOS 26 path

1. Install and launch Pocket Financer once; finish onboarding.
2. In Settings, run the synthetic model test. Inspect its in-memory synthetic input, exact instructions/request, post-schema `ParsedAlertDraft`, validation result/validated fields, safe failure details, timing, configuration, and Apple API-limit list. Confirm it creates no transaction or persistent `ExtractionRun`; record only its safe category and latency outside the app. Simulator readiness is not a substitute for this device check.
3. In Shortcuts, create a personal Message automation with `Message Contains debited` for the first proof. Do not add a Sender condition.
4. Add `Import Transaction Alert`. Set Message Body to `Shortcut Input`, then select its `Content` property. Leave Sender, Received At, and Source Application empty; the app uses the automation execution time.
5. Choose Run Immediately and save the automation.
6. Send a synthetic debit alert while the phone is unlocked, then while locked after one unlock.
7. Open the alert's **Processing Details** and confirm it shows the exact
   persisted filter decision, cumulative structured-generation JSON snapshots,
   exact instructions/request, the post-schema `ParsedAlertDraft`,
   classification/direction/amount/account/counterparty validation-stage outcomes,
   host-owned receipt-time provenance, response/total timing, safe result code,
   disposition, and immutable accepted transaction snapshot. Confirm raw
   snapshots, mapped fields, and the current ledger are labeled separately; the
   model and Review must not replace the receipt time.
8. Under frozen v4, confirm the grounded result appears exactly once in Review,
   then confirm it and verify exactly one transaction appears. For the planned
   successor route, separately verify that a complete valid uniquely resolved
   non-duplicate result enters Transactions without a review case. Replay the same
   normalized body within 15 seconds and confirm duplicate handling remains
   version-correct even when sender metadata differs.
9. Edit the transaction and confirm **Edited by owner** changes while the original run's draft and accepted snapshot remain unchanged. Retry it and confirm Pocket Financer preserves the owner correction without starting another model attempt or changing the historical run.
10. After the proof works, create three otherwise identical automations for `Rs`, `INR`, and `₹`, then remove the `debited` automation. Multiple Message criteria are AND, so the currency markers must not be placed together in one trigger.
11. Disable Apple Intelligence or use a not-ready state; confirm the alert remains pending and succeeds after retry.
12. Force-quit or reboot between delivery and parsing; confirm the durable queue recovers.

Never capture or share a Processing Details screenshot containing an alert, prompt, draft, evidence, sender, account, or transaction value. Record only privacy-safe categories, timing, and whether each expected section behaved correctly.

## Store-recovery validation

Do not corrupt or replace a personal iPhone store to test recovery. In an isolated Debug simulator/install, launch with `--ui-testing-store-unavailable` and verify:

1. **Local store unavailable** replaces the normal app UI.
2. The screen says the existing store was not deleted, reset, or replaced and that imports are paused.
3. A safe category/code and **Retry Local Store** are visible; no financial content appears.
4. No empty ledger, onboarding flow, or in-memory fallback becomes available behind the error.
5. Remove the launch argument and relaunch to confirm a normal isolated test store can open; do not interpret this injection as a real migration test.

Separately, unit/integration validation must cover the V1-to-V4 lightweight migration path, preservation of V2 extraction runs and V3 generation snapshots, an injected `storeUnavailable` result from `AlertIngestionService.ingestLive`, and preservation of an unsupported pre-baseline store and sidecars. The App Intent must convert that failure to `localStoreUnavailable`, explicitly say the alert was not saved, and create no alert or extraction run.

## iOS 27 beta exploration

On the beta device, separately evaluate the newer notification automation:

- Whether Messages is a selectable source.
- Which notification fields are actually provided to the shortcut.
- Whether keyword filters preserve the complete alert.
- Locked-device execution and confirmation behavior.
- Behavior after reboot and before first unlock.

Treat this as an experiment until stable Apple documentation defines source support and payload shape. Do not replace the stable Message automation or add an iOS 27 deployment dependency based solely on beta behavior.

## Release gate

Automatic ingestion remains labeled experimental until the stable path passes the full matrix on a physical phone. Manual paste/import is the supported fallback.
