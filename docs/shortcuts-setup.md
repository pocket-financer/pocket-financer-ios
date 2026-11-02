# Shortcuts setup on iOS 27

Pocket Financer cannot create or inspect a personal automation. This one-time configuration belongs to the iPhone owner. These steps describe the iOS 27 inline Shortcuts editor and avoid the separate Siri-powered **Describe a change** interface.

## Before starting

1. Install the latest Pocket Financer build and open it once so iOS indexes `Import Transaction Alert`.
2. In Pocket Financer, complete onboarding and run **Settings → Run Synthetic Model Test**.
3. Use only a rewritten synthetic test message. Never put a real bank alert in a screenshot, issue, or repository.

## First proof: `debited`

1. Open **Shortcuts** and tap **Automation** in the bottom tab bar. Do not start from the **Shortcuts** tab's `+` button.
2. If this is your first automation, tap **New Automation**. Otherwise tap **+** in the top-right.
3. Choose **Message** under **Communication**. This is the trigger; do not search for or choose the **Find Messages** action.
4. Leave **Sender** empty and set **Message Contains → debited**.
5. Choose **Run Immediately**. On an older presentation, turn off **Ask Before Running** instead. Continue with **Next** or **Done**, whichever this beta shows.
6. Choose **New Blank Automation** when offered, then tap **Add Action**. If the inline editor is already visible, use its narrow **Search Actions** field.
7. Open **Apps → Pocket Financer → Import Transaction Alert**. Searching the exact action name `Import Transaction Alert` is an equivalent fallback.
8. Tap the action's blue **Message Body** slot, choose **Select Variable**, then choose the blue **Shortcut Input** produced by the Message trigger.
9. Tap the inserted **Shortcut Input** token and select its **Content** property.
10. Leave **Sender**, **Received At**, and **Source Application** empty. The Message payload does not expose a reliable received-date property; Pocket Financer uses the automation execution time.
11. Confirm the action reads **Import transaction alert from Content**, then tap **Done**.

The resulting flow should be equivalent to:

```text
When I receive a Message where Message Contains debited
  → Import transaction alert from Content
```

## Test safely

Send a synthetic SMS to this iPhone from a different phone. It must contain a currency amount, a masked account/card cue, and a completed transaction verb. For example:

```text
Demo Bank: Rs.500.00 debited from a/c XXXXXX0000 on 05-08-2026 at Demo Store.
```

Verify that:

1. Shortcuts reports an automatic run without asking for confirmation.
2. Pocket Financer has exactly one inbox result.
3. The automation reports that the alert was saved locally; it does not wait for the model.
4. Open Pocket Financer. Under frozen v4, a grounded result appears in Review for
   owner confirmation; failures remain in a privacy-safe retry/review state. The
   planned successor route will allow a complete valid result to enter
   Transactions directly.

## Production-like sender-independent coverage

`debited` is useful for the first proof but misses many credit, card, transfer, refund, and payout alerts. Once the proof succeeds:

1. Duplicate the working shortcut three times.
2. Set the Message Contains value to `Rs`, `INR`, and `₹`, one value per automation.
3. Keep Sender empty in every copy.
4. Remove or disable the original `debited` automation so debit messages do not intentionally fire twice.

Do not put all three currency terms into one Message trigger. Apple combines multiple communication criteria with AND rather than OR. A message that happens to match two separate automations may run twice; Pocket Financer's sender-independent normalized-body duplicate window absorbs deliveries that arrive within 15 seconds.

## Troubleshooting

### Siri chat opens

Close it with **×**, return to **Automation**, and select the **Message** trigger from the trigger picker. Only use the narrow **Search Actions** text field after the Message trigger is configured and the blank automation editor is visible. Avoid the microphone and **Describe a change**.

### Pocket Financer is not listed

Open the newest Pocket Financer build once, return to Shortcuts, and search the exact action name `Import Transaction Alert`. If an older build was replaced, force-close and reopen Shortcuts to refresh App Intent metadata.

### Message Body is missing

The installed app is stale. The current action metadata includes an interactive Message Body parameter. Reinstall the latest build, open Pocket Financer once, then reopen Shortcuts.

### The action says the alert was saved

That is the expected result: the automation performs only the durable local inbox write and returns without waiting for Apple Foundation Models. Open Pocket Financer to process its queue. Use **Settings → Run Synthetic Model Test** for the detailed model report; retryable failures remain queued, while unsupported or uncertain results retain evidence for manual review.

## Physical-device validation still required

Apple documents the Message trigger and automatic execution, but its public documentation does not contractually enumerate every Message value property supplied to third-party actions. `Content`, `Sender`, and `Recipients` are present in the current system implementation; the iOS 27 physical iPhone remains the release gate for payload, background, and locked-device behavior.

References:

- [WWDC26: Explore new automation features in Shortcuts](https://developer.apple.com/videos/play/wwdc2026/310/)
- [Apple: Communication triggers in Shortcuts](https://support.apple.com/en-lamr/guide/shortcuts/apdd711f9dff/ios)
- [Apple: Use variables in Shortcuts](https://support.apple.com/guide/shortcuts/use-variables-apdd02c2780c/ios)
- [Apple: Add parameters to an App Intent](https://developer.apple.com/documentation/appintents/adding-parameters-to-an-app-intent)
