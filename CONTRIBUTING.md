# Contributing to Pocket Financer (iOS)

Pocket Financer handles sensitive local financial data. Read [AGENTS.md](AGENTS.md) first and keep every change focused, privacy-safe, and auditable. `main` is a protected, releasable branch; all work lands through short-lived branches and pull requests.

## Workflow

1. Branch from up-to-date `origin/main` using `<type>/<short-description>` (for example `feat/review-span-editing`, `fix/duplicate-window`, or `docs/shortcuts-clarity`).
2. Keep changes scoped and add or update synthetic unit and UI tests (`PocketFinancerTests` / `PocketFinancerUITests`).
3. Verify locally on macOS (or confirm all checks pass on the pull request CI run):
   - `scripts/format.sh --lint`
   - `CONFIGURATION=Release scripts/build.sh`
   - `scripts/test.sh`
   - If you touched synced contract assets, run `python ../pocket-financer-intelligence/scripts/sync_native_assets.py --check --target ios`.
4. Open a pull request targeting `main` with a Conventional Commit title (`feat:`, `fix:`, `perf:`, `refactor:`, `revert:`, `test:`, `docs:`, `build:`, `ci:`, `chore:`), because the squash-merge title becomes the commit on `main`.
5. For ingestion or persistence changes, document duplicate handling, crash recovery, raw-evidence retention/tombstones, schema migration impact, and model-unavailable behavior in the PR description.
6. For UI changes, verify Dynamic Type, VoiceOver labels, dark mode, and Reduce Motion on an iPhone simulator.

## Privacy & data hygiene

Never include a real financial alert, phone number, account identifier, transaction screenshot, signing credential, or model transcript in code, tests, docs, issues, or pull requests. Replace every value with freshly invented synthetic data.

## Merging & releases

Use squash merge after required checks (`Format, build, and test` and `Conventional Commit title`) pass and review conversations are resolved, then delete the branch. Never push directly to `main`.

Release Please owns routine version bumps, `CHANGELOG.md`, tags, and draft releases. Do not manually edit version or changelog files in normal PRs. See [docs/releasing.md](docs/releasing.md).
