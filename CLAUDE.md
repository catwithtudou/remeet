# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

回见 · Remeet is a macOS menu-bar app (no Dock icon) that resurfaces the user's saved notes as a card next to the notch on a schedule. It is built with Swift 6, SwiftUI and AppKit, targets macOS 14+, ships arm64 only, and has no third-party dependencies. The UI strings, README and `docs/` are written in Chinese, so keep new user-facing text in Chinese. The deeper reference is `docs/DEVELOPMENT.md` (build/test/compatibility contracts) and `docs/UPDATING.md` (in-app update design). If a local `CONTEXT.md` exists (it is gitignored), it holds the domain glossary (立即回顾 vs 换一条回顾, 阅读期, 暂停展示, etc.) and current release status.

## Commands

```sh
./scripts/test.sh                                   # all Swift tests (Swift Testing, not XCTest)
./scripts/test.sh --filter contentScaleRoundTrip    # single test / suite by name
./scripts/test.sh --skip NativeWindowTests          # no GUI session available

# Python tests (stdlib unittest). Requires the Debug binary from the Swift test run;
# without REMEET_TEST_BINARY the reload/installer integration cases are skipped.
REMEET_TEST_BINARY=.build/debug/Remeet python3 -m unittest discover -s Tests -v
REMEET_TEST_BINARY=.build/debug/Remeet python3 -m unittest discover -s Tests -p test_reload_bridge.py -v

# Build an .app (refuses to overwrite an existing output; pick a fresh path)
./scripts/build-app.sh release
REMEET_APP_OUTPUT="$PWD/build/debug-candidate/Remeet.app" ./scripts/build-app.sh debug

# Typecheck as a single module (matches the Xcode target) without full Xcode
xcrun swiftc -typecheck -parse-as-library -swift-version 6 \
  -target arm64-apple-macosx14.0 Sources/RemeetCore/*.swift Sources/Remeet/*.swift
plutil -lint Resources/Info.plist Remeet.xcodeproj/project.pbxproj

# Website and public-file checks (CI runs all of these)
python3 website/check.py && node --check website/dist/site.js
git diff --cached --check && python3 scripts/audit-public.py   # audits the STAGED index only
```

Run the Debug app in isolation so it never touches real notes or preferences (these env vars are honored only in DEBUG builds; Release ignores them):

```sh
REMEET_DATA_DIR="$PWD/build/qa-data" REMEET_DEFAULTS_SUITE=local.Remeet.qa \
  build/debug-candidate/Remeet.app/Contents/MacOS/Remeet --settings   # or --preview
```

`scripts/test.sh` adds framework/rpath flags that some Command Line Tools installs need. If tests fail at link time before running (e.g. `PackageDescription` link errors), treat it as a toolchain mismatch. Don't work around it by changing app code or lowering the Swift version.

## Architecture

**Two build systems, one source tree.** In SwiftPM, `Sources/RemeetCore` (pure logic: content, scheduling, presentation state, settings) is its own module and `Sources/Remeet` is the app. `Remeet.xcodeproj` compiles both directories into a single `Remeet` target. As a result:
- App files guard `import RemeetCore` with `#if SWIFT_PACKAGE`, and RemeetCore API used by the app must be `public`.
- `project.pbxproj` is maintained by hand. A new source file must also be added there (file ref + group + sources build phase).

**One executable, several modes** (`App.swift`, `RemeetApp.main`):
- `--install-update <plan.json>`: a copy of the app runs as the update helper (`UpdateInstaller.run`).
- `--reload-content <path>`: a headless CLI that asks the running instance to reload over `DistributedNotificationCenter` and prints a JSON reply (`ContentReloadBridge`).
- DEBUG only: `--preview` and `--settings`, plus a "模拟定时触发" menu item.
- Otherwise it runs as an accessory app with a status item.

**Runtime wiring.** `AppDelegate` owns `RecallModel`, `UpdateController` and `ContentEditorSession` (in `SettingsView.swift`), and rebuilds the status menu in `menuNeedsUpdate`. `RecallModel` is the hub:
- It combines `QuoteStore` (file), `PreferenceStore` (UserDefaults), `QuoteSelection` (random current entry), `ActivityGate` (sleep/screen sleep/session/lock reasons) and `RecallScheduler`.
- It pushes state to `NotchPanelController` through `syncPanel()`.
- `NotchPanelController` hosts the SwiftUI card in a non-activating `NSPanel` and drives `PresentationState`, a pure state machine for hover and reading deadlines that uses monotonic time.

**Quit/close always goes through draft protection.** `applicationShouldTerminate` calls `updater.prepareToTerminate(protectDrafts:)`, which calls `ContentEditorSession.prepareToClose`. The editor window close, ⌘Q and update-and-restart all share this path. Don't add exit paths that skip it.

**Content invariants (`QuoteStore`).**
- `QuoteStore.normalize` is the single normalization rule (trim, drop blanks, keep the first entry for duplicate text). It is shared by load, save, import preview and the pre-save warning.
- `save(_:expectedFileData:)` checks the on-disk bytes against the editor's baseline, both before and after backing up. A mismatch throws `changedOnDisk`, and the draft is never silently overwritten.
- Before an atomic write, the old bytes are backed up to `editor-backups/` (max 10). If the backup fails, the save is refused.
- The live pool updates only after the write succeeds.
- An invalid file is rejected whole and the previous valid data is kept. A valid `[]` empties the pool.

**Scheduling (`RecallScheduler`).**
- Preset frequencies (30/60/120) align to wall-clock slots, including both DST repeats. Custom intervals count from an anchor.
- A timer callback that fires more than 5 s late becomes `.recovered` (silent reselect), never a catch-up popup.
- Manual recalls never shift the schedule.
- `now`, `calendar` and `armTimer` are injectable for tests.

**In-app updates.**
- `ReleaseUpdate.swift` handles the GitHub Releases client, semver and channel selection, paging through the releases list instead of using `latest`.
- `UpdateController` handles UI state, download and verification.
- `UpdateInstaller.swift` (`UpdateFiles`, the helper process, `RENAME_SWAP`, rollback) handles installation.
- Automatic replacement is off (`UpdateController.installsAutomatically` defaults to `false`; only tests turn it on). Current ad-hoc builds download, verify, then guide a manual Finder replacement; Finder is revealed only after draft protection allows quitting. Quarantine is never removed and Gatekeeper is never bypassed. Signing alone must not re-enable it (see `docs/UPDATING.md`).
- Read `docs/UPDATING.md` before changing this flow.

**Other parts of the repo.**
- `skills/remeet/` is an optional agent skill. Its Python helper `scripts/content.py` (`convert`/`plan`/`apply`) is tested by `Tests/test_content_skill.py`.
- `website/dist/` is a static site deployed by `.github/workflows/pages.yml`.
- The app does not depend on either.

## Compatibility contracts. Do not rename these.

Pre-rename identifiers are kept so upgrades keep user data:
- Bundle ID / UserDefaults domain: `local.NotchRecall`
- Data file: `~/Library/Application Support/NotchRecall/quotes.json`
- IPC: `local.NotchRecall.reloadContent` / `reloadContentReply`, and Info.plist `NotchRecallContentReloadVersion`
- Content JSON: a UTF-8 array of `{text, source?, tags?}`, where optional fields are never null. Empty `tags` are omitted on save. Unknown fields are ignored by the app but rejected by the skill helper.
- Preference keys and their valid ranges in `RecallSettings`/`PreferenceStore`: out-of-range values fall back to defaults.

CI builds the `v0.2.14` tag and sets `REMEET_TEST_OLD_BINARY` to test replacing an old process with the current binary against the same data. Keep that test passing.

## Gotchas

- **SwiftUI `Binding` setters:** use explicit closures (`set: { value in model.setX(value) }`) rather than passing method references. Method references have crashed the Swift 6.1 compiler that CI (macOS 15) uses, even when they build locally. This has been fixed twice already.
- **Swift tests use Swift Testing:** `@Test`/`#expect`, with `@testable import Remeet` / `RemeetCore`. `NativeWindowTests` needs a logged-in graphical session.
- **No real data in tests:** tests use temp dirs and isolated defaults suites. Never point tests or screenshots at real notes.
- **Build kinds:** `build-app.sh release` still marks the app `RemeetBuildKind=development`. Only `package-release.sh` stamps `release` and the tag, on a re-signed archive copy. Debug apps are refused for packaging. Version and build number live in `Resources/Info.plist`.

## Public-repo hygiene

- `scripts/audit-public.py` scans the staged Git index (not the working tree). It rejects:
  - personal absolute paths (`/Users/<name>/`)
  - tokens and private IPs
  - generated or local files
  - any binary asset whose SHA-256 is not pinned in `REVIEWED_ASSETS`
- After changing an image, review it and update its digest there. Screenshots must use sample content only.
- Local-only material is gitignored and must stay out of commits: `CONTEXT.md`, `Remeet_MVP_SPEC.md`, `docs/MANUAL_ACCEPTANCE.md`, `docs/RELEASE_REVIEW.md`, `build/`, imports/exports/backups.
- User-visible behavior changes should update `README.md` and the relevant `docs/` page (and the website copy if affected).
- Commit messages use conventional prefixes (`feat:`, `fix:`, `docs:`, `test:`, `chore:`, `perf:`, `ci:`, `refactor:`).
