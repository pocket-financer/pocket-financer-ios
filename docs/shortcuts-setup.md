# Shortcuts Automation Setup (iOS 26+)

Pocket Financer cannot create, read, or modify personal Shortcuts automations. This one-time setup belongs to the iPhone owner. The steps below describe the modern inline Shortcuts automation editor (including iOS 27 beta refinements) and avoid the separate Siri-powered **Describe a change** prompt.

## Before starting

1. Install the latest Pocket Financer build and open it once so iOS indexes `Import Transaction Alert`.
2. Complete onboarding, confirm your primary currency, and run **Settings → Run Synthetic Model Test**.
3. Use only a freshly written synthetic test alert. Never put a real bank SMS in a screenshot, issue, or repository.

## Step 1: First proof (`debited`)

1. Open **Shortcuts** and tap **Automation** in the bottom tab bar (do not start from the **Shortcuts** tab's `+` button).
2. Tap **New Automation** (or **+** in the top-right if you already have automations).
3. Under **Communication**, choose the **Message** trigger (do not pick the **Find Messages** action).
4. Leave **Sender** empty and set **Message Contains → `debited`**.
5. Select **Run Immediately** (on older presentations, disable **Ask Before Running**), then tap **Next** or **Done**.
6. Choose **New Blank Automation** when offered, then tap **Add Action** (or use the inline **Search Actions** bar).
7. Navigate to **Apps → Pocket Financer → Import Transaction Alert** (searching `Import Transaction Alert` is equivalent).
8. Tap the action's **Message Body** slot, choose **Select Variable**, and select **Shortcut Input** from the Message trigger.
9. Tap the inserted **Shortcut Input** token and select its **Content** property. Do not insert `Shortcut Input` a second time.
10. Leave **Sender**, **Received At**, and **Source Application** empty. The Message trigger does not expose a reliable received timestamp; Pocket Financer uses the local automation execution time.
11. Confirm the action reads **Import transaction alert from Content**, then tap **Done**.

The completed automation should read:

```text
When I receive a Message where Message Contains debited
  → Import transaction alert from Content
```

## Step 2: Test safely with synthetic data

Send a synthetic SMS to your iPhone from another phone containing a currency amount, a masked account or card reference, and a completed transaction verb:

```text
Demo Bank: Rs.500.00 debited from a/c XXXXXX0000 on 05-08-2026 at Demo Store.
```

Verify that:

1. Shortcuts runs automatically without asking for confirmation.
2. The action reports that the alert was saved locally without waiting for Apple Foundation Models.
3. Opening Pocket Financer shows one inbox item:
   - First time for an unlinked account suffix/VPA: opens **Review**; confirming creates both the `Transaction` and the confirmed `Account` + `SmsAccountAlias`.
   - Subsequent valid transactions for the same linked account outside the 5-minute duplicate window save automatically to **Transactions** (matching transactions within 5 minutes open **Review** as `duplicate_possible`).
   - OTP or non-transaction alerts settle as body-free tombstones (`tombstoned_excluded` or `tombstoned_none`).

## Step 3: Sender-independent coverage (`Rs`, `INR`, `₹`)

`debited` proves the flow but misses credits, refunds, card spends, and payouts. Once the proof succeeds:

1. Create three identical copies of the working automation with **Message Contains** set to `Rs`, `INR`, and `₹` (one token per automation).
2. Keep **Sender** empty in every copy.
3. Remove or disable the initial `debited` automation to avoid intentional double triggers.

Do not combine all three terms into one Message trigger: Apple joins multiple criteria with **AND**, not **OR**. If one alert matches two separate automations (for example `Rs` and `INR`), Pocket Financer's 15-second sender-independent deduplication window absorbs the overlap safely.

## Troubleshooting

- **Siri chat opens:** Dismiss it with **×**, return to **Automation**, pick the **Message** trigger, and use only the inline **Search Actions** field inside the blank automation editor.
- **Pocket Financer is missing from Apps:** Launch the newest Pocket Financer build once, force-close and reopen Shortcuts, and search `Import Transaction Alert`.
- **Message Body parameter is missing:** Reinstall the current build, launch Pocket Financer once to refresh App Intent metadata, and reopen Shortcuts.
- **Action says the alert was saved locally:** Expected behavior. Background App Intent execution only commits durable local evidence; open Pocket Financer to drain the queue with Apple Foundation Models.

## Physical-device validation caveat

Apple documents the Message trigger and automatic execution, but its public documentation does not contractually enumerate every property on the Message payload supplied to third-party App Intents. `Content`, `Sender`, and `Recipients` are currently exposed; validate payload delivery, background execution, and locked-device behavior on a physical iPhone using [device-validation.md](device-validation.md).

## References

- [WWDC26: Explore new automation features in Shortcuts](https://developer.apple.com/videos/play/wwdc2026/310/)
- [Apple: Communication triggers in Shortcuts](https://support.apple.com/en-lamr/guide/shortcuts/apdd711f9dff/ios)
- [Apple: Use variables in Shortcuts](https://support.apple.com/guide/shortcuts/use-variables-apdd02c2780c/ios)
- [Apple: Add parameters to an App Intent](https://developer.apple.com/documentation/appintents/adding-parameters-to-an-app-intent)
