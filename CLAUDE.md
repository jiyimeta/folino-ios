# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

Folino is a universal iOS app (iPad + iPhone, Swift 6.3, iOS 26+, bundle id `com.KeyNumber.Folino`). Product specs live in `docs/product/`; the implementation strategy lives in `docs/engineering/module-architecture.md` — read the latter before making structural changes.

## First-Time Setup

```sh
cp Config/Local.xcconfig.sample Config/Local.xcconfig
# edit Local.xcconfig to set your Apple Developer Team ID

xcodegen generate
open Folino.xcodeproj

# install the pre-commit hook (one-time per clone)
brew install pre-commit swiftlint swiftformat   # if not already installed
pre-commit install
```

(The bundled SoundFonts are committed under `App/Resources/Soundfonts/` — no manual copy step.)

`Config/Local.xcconfig` is gitignored; the team ID never lands in the repo. The generated `Folino.xcodeproj` is also gitignored and must be regenerated whenever `project.yml` changes.

## Git Workflow

**Do not use partial / hunk-level staging** (`git add -p`, `git add --patch`, IDE "stage selected lines"). Always stage whole files.

The pre-commit hook (configured in `.pre-commit-config.yaml`) runs SwiftFormat and `swiftlint --fix` against staged Swift files and writes fixes back to disk. With partial staging, those fixes can land on hunks you intentionally left unstaged, mixing them into the commit and corrupting the split.

To break a working tree into multiple commits:

1. `git stash --keep-index` — sets aside everything that isn't staged.
2. Commit the staged whole files (the hook will fix-and-fail until clean).
3. `git stash pop` — restores the rest, then stage the next batch.

If you have unrelated edits in the same file, use `git stash`, edit again, and commit in passes — never split by hunk.

## Day-to-Day Commands

| Action | Command |
| --- | --- |
| Regenerate Xcode project after editing `project.yml` | `xcodegen generate` |
| Build app (project, simulator) | `xcodebuild -project Folino.xcodeproj -scheme Folino -destination 'platform=iOS Simulator,name=iPhone 16' -skipPackagePluginValidation build` |
| Run app + UI tests | `xcodebuild -project Folino.xcodeproj -scheme Folino -destination 'platform=iOS Simulator,name=iPhone 16' -skipPackagePluginValidation test` |
| Test one Swift package in isolation | `cd Packages/<Layer>/<Name> && swift test` |
| Run a single Swift Testing suite/test | `swift test --filter <SuiteName>` |

For feature-isolated iteration (SwiftUI previews, fast unit-test loop), open the relevant `Packages/.../Package.swift` directly in Xcode rather than the app project.

## Architecture (must respect)

Strict layered SPM modules. **Read `docs/engineering/module-architecture.md` for details** — the rules below are summary only.

```
App ──▶ Features ──▶ Domain ◀── swift-sheet-music
 │                    ▲
 └──▶ Infrastructure ─┘                Utility is reachable from any layer.
```

- **`Packages/Utility/`** — app-agnostic building blocks (`UtilityCore`, `UtilityUI`, `Navigation`).
- **`Packages/Domain/`** — value types + protocols. Foundation-only.
- **`Packages/Infrastructure/`** — concrete adapters (`Persistence`, `CloudSync`, `Soundfonts`, `Audio`, `ScoreFiles`).
- **`Packages/Features/<Name>/`** — one package per feature (Library, Reader, Editor, ImportExport, Settings).
- **`App/`** — composition root. The only place that wires Infrastructure adapters into Feature view models.

`swift-sheet-music` is consumed by Domain (model re-export) and Infrastructure (adapters). Features never import it directly.

**Forbidden** (will be flagged in review):

- Feature → Feature (lift shared code into Domain or compose at App).
- Feature → Infrastructure (always go through a Domain protocol).
- Feature → `swift-sheet-music` directly.
- Domain → Infrastructure / Features / App.
- Utility → anything else in this repo.

### Dependency Injection

Pure constructor injection. No DI library. View models take Domain protocols via `init`. SwiftUI `EnvironmentValues` is reserved for view-tree-scoped concerns (theme, navigation, feature flags) — never used as a service locator for view models.

## Testing

- **New tests use Swift Testing** (`import Testing`, `@Suite`, `@Test`, `#expect`). UI tests still need `import XCTest` for `XCUIApplication`.
- **Feature tests** run against hand-written fakes that implement Domain protocols — no real CloudKit, no real network, no real audio engine.
- **Domain tests** are pure value-type unit tests.
- **Infrastructure tests** can hit real SQLite / tmpdir file I/O. CloudKit, audio, and HTTPS adapters use fakes.

## Build-Time Tooling

These plugins run automatically on every `xcodebuild` / Xcode build — no manual invocation:

- **SwiftLintBuildToolPlugin** (`SimplyDanny/SwiftLintPlugins`) — applied to every Package source target and the App target. Config is the repo-root `.swiftlint.yml`.
- **PrepareLicenseList** (`cybozu/LicenseList`) — extracts third-party license texts at App build time. Surface them via `LicenseListView()` from `import LicenseList`.

## Comment style

Reflow comment paragraphs (`//` and `///`) at the SwiftLint `line_length.warning: 120` budget, not 80. Older code may still be wrapped at ~80 — reflow as you touch it. Aim to keep prose paragraphs as a single line up to 120 characters wide; only break for the reasons below.

Preserve as-is (do not reflow across these):
- Directives: `// MARK:`, `// swiftlint:…`, `// swift-format…`, `// sourcery:`.
- Blank comment lines (`//` or `///` with no body) — they mark a paragraph break.
- Markdown structure inside a comment — `- ` / `* ` / numbered list, `# ` headings, `> ` blockquotes, `` ``` `` fences. Each starts a new paragraph.
- Preformatted content — comment bodies that begin with 2+ leading spaces (indented code samples, ASCII tables).
- Decorative dividers like `////…` or `// ====`.

Hyphenated soft breaks (`long-\nrunning`) join back into one word when the next line begins with a letter — `long-running`, not `long- running`.

## Project Constraints

- **App name is lowercase `folino` for users.** `Folino` is only for type names, the SwiftPM/Xcode scheme name, the project name, and the bundle ID prefix — strictly developer-facing. Anywhere a user can read the brand (Info.plist `CFBundleDisplayName`, navigation titles, alert titles, share-sheet display, marketing copy), it must be lowercase `folino`.
- **Do not propose AudioKit (the third-party library)**. Folino uses AVFoundation directly via `swift-sheet-music`'s `SheetMusicAudio`.
- **No GPL dependencies.** Hard constraint.
- Bumping a SwiftPM dependency means updating both the relevant `Package.swift` AND the `from:` entry under `packages:` in `project.yml` to the same version.
- Localization for `Info.plist` strings goes in `App/Resources/InfoPlist.xcstrings`.

## Autonomous-task ground rules

When the user hands off a long-running task and steps away, default to **proceed without asking** for routine work, and **stop to confirm** only at the boundaries below. The y/n prompts the user actually sees should all be ones where the answer might genuinely be "no".

**Proceed without confirmation:**
- Reading, editing, writing files inside this repo.
- Running builds, tests, previews (`xcodebuild`, `swift test`, `xcrun simctl`, `mcp__xcode__*`).
- Routine git: `add`, `commit`, `checkout`, `switch`, `stash`, `restore`, `fetch`, `pull --ff-only`, status / diff / log / show / blame.
- SwiftLint / SwiftFormat / pre-commit fix-and-restage cycles.
- Bumping a SwiftPM dependency version when the task explicitly asks for it (still update both `Package.swift` and `project.yml`).

**Stop and confirm — these are not auto-approved by `.claude/settings.json` and never should be:**
- Spec / product behavior changes — anything that alters what `docs/product/` describes, user-visible copy, or feature scope.
- Module-architecture changes — new packages, new layer boundaries, anything in `docs/engineering/module-architecture.md`.
- Public API changes to a Domain protocol that ripples across multiple Features.
- Adding, removing, or replacing a SwiftPM dependency (vs. version bump of an existing one).
- Destructive git: `push`, `push --force`, `reset --hard`, `clean -f*`, `branch -D`, `worktree remove`, history rewrites.
- Destructive shell: `rm -rf` of the repo root, `$HOME`, or any worktree.
- GitHub side effects: `gh pr merge`, `gh pr close`, `gh pr edit`, `gh release create/delete`, `gh repo delete/archive`.
- Editing `.claude/settings.json`, `.claude/settings.local.json`, `~/.claude/settings.json`, or this "Autonomous-task ground rules" section — anything that would relax my own auto-approval rules.
- Touching paths outside this repo (`../OtherProject`, other worktrees, `~/Library/...` beyond Xcode DerivedData cleanup that's clearly necessary for the task).

If something falls between these — e.g. a refactor that *might* qualify as architectural — surface the question before doing the work, not after.
