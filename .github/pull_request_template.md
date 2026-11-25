## What changed

Describe the user-visible or architectural outcome and why this is the smallest useful change.

## Verification

- [ ] `scripts/format.sh --lint`
- [ ] `CONFIGURATION=Release scripts/build.sh`
- [ ] `scripts/test.sh`
- [ ] `python ../pocket-financer-intelligence/scripts/sync_native_assets.py --check --target ios` (when contract assets or prefilter vectors changed)
- [ ] Tested on an iPhone simulator
- [ ] Tested on a physical iPhone when Shortcuts, App Intents, Foundation Models, signing, or data protection changed (see `docs/device-validation.md`)

## Privacy, recovery & accessibility

- [ ] No real financial alert, identifier, signing credential, or model transcript is included
- [ ] No new network, cloud, analytics, or third-party runtime dependency was added
- [ ] Ingestion or persistence changes document duplicate handling, crash recovery, raw-evidence retention/tombstones, schema migrations, and model-unavailable behavior
- [ ] UI changes were checked with Dynamic Type, dark mode, Reduce Motion, and VoiceOver labels
