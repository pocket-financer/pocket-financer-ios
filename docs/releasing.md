# CI, Branching, and Releasing

Pocket Financer uses protected pull requests, required CI checks, and Release Please as a controlled release gate. Development proceeds through short-lived branches while the repository owner chooses if and when to merge the automated draft release pull request. TestFlight and App Store distribution are deliberately outside automatic GitHub release preparation.

Executable workflow files under `.github/workflows/` are the final authority. Update this guide in the same pull request whenever CI or release behavior changes.

## Pull-request CI

`.github/workflows/ci.yml` runs on pull requests targeting `main`, pushes to `main`, and manual dispatches. Its required job is named **`Format, build, and test`** (matching `.github/rulesets/main.json`) and performs:

- Xcode (`26.6`) and iOS Simulator (`iPhone 17 Pro`, iOS `26.5`) toolchain reporting.
- Project, privacy-manifest, scheme, JSON config, shell syntax, Release Please dispatch-contract, and bundled `SmsProcessing` SHA-256 manifest verification.
- Rejection of remote Swift packages, app networking/cloud APIs (`CloudKit`, `Network`, `URLSession`), raw SMS corpora, and signing material.
- Strict `swift-format` lint (`scripts/format.sh --lint`).
- Unsigned Release simulator build (`CONFIGURATION=Release scripts/build.sh`).
- Serial unit and UI smoke tests with code coverage (`ENABLE_CODE_COVERAGE=YES scripts/test.sh`).
- Fourteen-day artifact retention for `PocketFinancer.xcresult` and exported JSON coverage.

`.github/workflows/pr-title.yml` runs the required **`Conventional Commit title`** check on PR events and `workflow_dispatch` invocations from `release.yml`.

CI uses one `iPhone 17 Pro` simulator with parallel test destinations disabled to reduce memory pressure and simulator nondeterminism. Superseded PR runs cancel automatically, while pushes to `main` are never cancelled mid-run.

`scripts/test.sh` defaults local `ENABLE_CODE_COVERAGE` to `NO` to reduce local disk and memory overhead; CI sets `ENABLE_CODE_COVERAGE=YES`.

## Version and release preparation

`version.txt`, `Config/Version.xcconfig`, `CHANGELOG.md`, `.release-please-manifest.json`, `release-please-config.json`, and `.github/workflows/release.yml` define the automated release flow:

- `fix:` requests a patch version bump.
- `feat:` requests a minor version bump.
- `feat!:` or a `BREAKING CHANGE:` footer requests a major version bump.
- `docs:`, `test:`, `refactor:`, `build:`, `ci:`, and `chore:` commits do not request a release by themselves.
- Release Please maintains a single draft release pull request.
- Merging that release pull request creates an immutable `v<version>` tag and a draft GitHub Release that remains unpublished until reviewed and published manually.
- GitHub Actions never builds, signs, uploads, or distributes an `.ipa`.

`release.yml` runs in a non-cancelling `stable-release` concurrency group. When `RELEASE_PLEASE_TOKEN` is unset, it uses the built-in `GITHUB_TOKEN` and explicitly dispatches both `ci.yml` and `pr-title.yml` against the release-PR head branch so required ruleset checks still execute.

## Reproducible repository controls

`.github/rulesets/main.json` is the version-controlled definition of the active `main` branch ruleset. Keep it synchronized with the live GitHub ruleset whenever policy changes:

- Pull requests required; squash merge only; linear history enforced; branch deletion and force pushes blocked; no routine administrator bypass.
- Required status checks against up-to-date `main`: **`Format, build, and test`** and **`Conventional Commit title`**.
- Review threads must be resolved before merge.
- Zero mandatory approvals while single-owner; increase in `.github/rulesets/main.json` when a second reviewer joins.
- Default Actions token set to read-only with permission for Actions to create pull requests (for Release Please).

## Optional release token

The built-in `GITHUB_TOKEN` fallback is supported out of the box. If a dedicated identity is later desired, create a fine-grained PAT scoped strictly to this repository's contents, issues, and pull requests and store it as `RELEASE_PLEASE_TOKEN`. Rotate before expiry and never print its value in logs.

## Routine development and release flow

1. Create `<type>/<short-description>` off current `origin/main` (for example `feat/account-alias-picker` or `chore/overhaul-tests-docs-ci`).
2. Implement and verify a focused change.
3. Open a pull request targeting `main` with a Conventional Commit title.
4. Wait for **`Format, build, and test`** and **`Conventional Commit title`** to turn green, resolve any review threads, and squash-merge.
5. Release Please opens or updates its draft release pull request when release-relevant commits reach `main`.
6. When ready to release, inspect the version, `CHANGELOG.md`, CI checks, migration impact, and physical-device validation ([device-validation.md](device-validation.md)), then merge the release PR explicitly.
7. Verify the immutable `v<version>` tag and draft GitHub Release before publishing manually.

Never manually edit `CHANGELOG.md`, `version.txt`, `Config/Version.xcconfig`, or `.release-please-manifest.json` in ordinary branches, and never manually create or retarget a `v*` tag.

## Apple signing and distribution

Personal Team development signing (`Config/Signing.local.xcconfig`, gitignored) is local-only and unsuitable for distribution. Future TestFlight or App Store delivery requires an Apple Developer Program team, stable bundle identifier, App Store Connect setup, privacy disclosures, export-compliance review, and a separately reviewed archive/upload workflow.

Never commit certificates, `.p12`, `.p8`, `.cer`, `.mobileprovision`, App Store Connect keys, passwords, or base64-encoded signing artifacts anywhere in Git, Markdown, issues, or logs.

## Hotfixes and bad releases

Never patch `main`, an existing tag, or a published release in place.

1. Branch `fix/<short-description>` from current `origin/main`.
2. Add the smallest safe fix and regression test.
3. Open a `fix:` PR, pass normal CI, and squash-merge.
4. Verify Release Please proposes the expected patch bump and merge only when ready to publish.

For a bad published release, preserve its tag and audit trail, note the issue in its release notes, and ship a higher fix-forward version.

## Troubleshooting

- **No release PR:** Verify a `feat:` or `fix:` commit reached `main`, inspect the `Prepare release` workflow run, and confirm GitHub Actions is allowed to create pull requests.
- **Release PR checks did not start:** Verify `dispatch-required-checks` in `release.yml` retains `actions: write`, both `ci.yml` and `pr-title.yml` accept `workflow_dispatch`, and the dispatch targets `--ref "$head_branch"`.
- **Wrong version proposed:** Check squash-merge titles and `release-please-config.json`; fix forward instead of moving tags.
- **Device-only behavior unverified:** Complete [device-validation.md](device-validation.md) on a physical Apple Intelligence-capable iPhone before publishing.
