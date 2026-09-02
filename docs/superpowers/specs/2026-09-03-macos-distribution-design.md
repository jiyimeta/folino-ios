# folino for macOS — Sub-project Ⅷ, Distribution

**Date:** 2026-09-03
**Status:** Approved direction. Implementation plan to follow.
**Umbrella spec:** `2026-08-31-macos-app-design.md` §9, row Ⅷ. Depends on Ⅲb only.
**Scope:** What it takes to put the Mac app in front of a user — the App Sandbox it must run inside, the signing and provisioning that go with it, a release lane, Mac screenshots, and the one behavior gap that withdrawing origin mirroring exposes: the Mac cannot export a score at all (§7).

Shipping is **not** in scope. §1 of the umbrella spec makes personal cloud sync (Ⅵb / SP2) a prerequisite for *shipping* macOS, and that is unchanged. Ⅷ ends when a signed, sandboxed build can be produced and uploaded to TestFlight; the decision to submit is the user's, later.

---

## 1. The umbrella spec's origin mirroring is withdrawn

Ⅷ was written to carry "App Sandbox + security-scoped bookmark persistence (what §1's origin mirroring actually requires)". **Origin mirroring is withdrawn**, permanently, and the bookmark persistence goes with it. `2026-08-31-macos-app-design.md` §1 is amended in the same commit as this spec.

### What was proposed

An imported score would remember its *origin* — a security-scoped bookmark to the file it came from — and mirror every save back to it. On by default, switchable per score. The stated purpose was to pay the one cost of not being a document-based app: "receive an `.mscz` over Drive/AirDrop, edit it, send it back" becomes open → edit → export rather than open → edit → ⌘S.

### Why it is withdrawn

**It reintroduces exactly the split §1 rejected MuseScore 4 for.** §1's case against a document model is that MuseScore 4 bolted the cloud onto local documents and now carries a permanent two-place split (Save / Save online / Save to cloud). Mirroring gives folino the same shape: a library item, plus a file on disk that can diverge from it. §1 presents the origin as write-only ("the library stays the single truth; the origin is only a write target"), but a file that exists on disk can be edited by anything — MuseScore, a sync client, the user. The moment it is, folino owes an answer to "which one wins", which is a conflict-resolution design nobody asked for.

**It is a platform split, not a per-score attribute.** §1 argued that making origin a per-score attribute avoids splitting the experience into two modes (`feedback_no_experience_divergence`). It avoids the mode split and introduces a platform split instead: mirroring presupposes a stable filesystem path, which exists on Mac and does not exist in the same form on iPad, iPhone, or Android. "Editing on the Mac also updates the original file, editing on the iPad does not" is the least explicable kind of difference.

**The write-back would damage the file it writes to.** `LiveScoreFileGateway.saveScore` routes `.mscz` through `SheetMusic.exportMSCZ(score, to:)`, which re-encodes the whole container from folino's `Score` model. It does not carry the source archive's other entries across — that is precisely why "`MSCZWriter` extra entries" is still open work in umbrella §9 row Ⅱ. So mirroring into a MuseScore-authored `.mscz` replaces it with folino's encoding and drops whatever folino does not model. Overwriting a file the user did not author with folino, by default, is not a defensible default.

**And it would silently do nothing for most scores.** `saveScore` throws `unsupportedFormat` for `.musicXML`, `.mxl`, `.midi`, and `.pdf`. Mirroring can only ever apply to `.mscz` / `.mscx` origins, so "on by default" would be inert for the majority of the library.

**The requirement that survives does not need it.** §1 also asks that "a subsequent open of the same file resolves to the same library item". That is content-hash duplicate resolution — `LiveScoreLibraryRepository+Duplicates.swift`, already shipped — and needs no bookmark.

### What replaces it

Export. The "edit it and send it back" workflow is served by writing the file out, one extra action — **and §7 builds that, because the Mac does not have it yet.** Withdrawing mirroring without it would leave scores unable to leave the Mac app at all.

If the need resurfaces it will take a different shape than a per-score bookmark, and should be designed then:

- **An explicit one-shot command** — File ▸ *Overwrite Original…*, chosen by the user, with the fidelity warning shown once. This is honest about being an export, and it is what a user who genuinely wants the round trip is asking for.
- **A watched external folder** — "my library *is* this Dropbox folder", the persona MuseScore actually serves. That is a library-source feature, not a per-score attribute, and it interacts with Ⅵb.

Neither is scheduled.

### Consequence for Ⅷ

No `security-scoped bookmark` persistence, no `score_items` columns, no Persistence migration v19, no Domain protocol change. **The sandbox requirement collapses to one entitlement** (`files.user-selected.read-write`), because the import path never needs long-lived access: `LiveScoreFileImporter.prepareImport` copies the picked file's bytes into the app's own storage while the security scope is open, and the comment there already says so ("Staging decouples the commit step from scope entirely").

---

## 2. App Sandbox

Mac App Store distribution requires the App Sandbox. The Mac target has no `CODE_SIGN_ENTITLEMENTS` at all today — `project.yml` sets it for `Folino` (iOS) and `FolinoScreenshot` only — so the Mac app currently runs unsandboxed and cannot be submitted.

### A Mac-specific entitlements file

New file `App/Mac/FolinoMac.entitlements`, referenced from the `FolinoMac` target. It is **not** shared with `App/Folino.entitlements`:

- `com.apple.security.app-sandbox` and `com.apple.security.files.*` exist only on macOS; iOS has no field for them.
- The two platforms will diverge further (Ⅵb adds iCloud on both; the App Group is team-ID-prefixed on macOS and bare on iOS).
- Sharing one file means every macOS-only key edit invalidates the iOS provisioning profile.

### What it declares, and why each one

| Key | Why |
| --- | --- |
| `com.apple.security.app-sandbox` | Required for Mac App Store distribution. |
| `com.apple.security.files.user-selected.read-write` | `MacCommands` drives `NSOpenPanel` for import; export writes through a save panel. Under the sandbox both go through Powerbox, and only the file the user actually picked crosses the boundary. |
| `com.apple.security.network.client` | **Not optional.** `Packages/Features/Settings` compiles for macOS with the high-quality SoundFont row intact (only `FeedbackMailView`, `VersionHistoryScreen`, and `ReaderModeSettingRows` are `#if os(iOS)`-gated), and `LiveMuseScoreGeneralProvider` backs it with a real `URLSessionDownloadTask` against GitHub Releases. Without this key the download fails silently once the app is sandboxed. |

### What it deliberately does not declare yet

**iCloud container / CloudKit** (needed by Ⅵb) and **App Groups** (needed by the deferred cross-app tasks, §8). Automatic signing regenerates the App ID capabilities and the provisioning profile when an entitlement is added, so declaring them ahead of use buys nothing and leaves capabilities enabled on the App ID that nothing exercises. They are added by the sub-project that needs them.

### Nothing else is gated by the sandbox

Audio playback is output-only (no `device.audio-input`). The library, the database, and the SoundFont directory are all under Application Support, which the sandbox relocates transparently (§3). No temporary exception entitlement is needed anywhere.

---

## 3. The library moves into the container, and no code changes

`AppPaths.documentsRoot` resolves `.applicationSupportDirectory` on macOS and appends `folino/`. For a sandboxed app, `FileManager` resolves that same call inside the container — `~/Library/Containers/com.KeyNumber.Folino/Data/Library/Application Support/folino/` — so the database, the scores directory, the staging directory, and `legacySoundfontsDirectory` all move together, with no source change.

The `PARITY(macos)` marker at `App/Shared/AppPaths.swift:6` is therefore **deleted**, not implemented. Its own prediction was right: "Application Support is already where that container's equivalent maps, so nothing here has to move twice in spirit."

**Pre-sandbox development data is abandoned, deliberately.** Data written by unsandboxed Mac dev builds stays at `~/Library/Application Support/folino/` and becomes invisible to the app. There are no macOS users, so a migration path would be code that never runs in production and has to be maintained forever. The QA sheet records how to copy the old directory into the container by hand if a specific test library is worth keeping.

---

## 4. Signing, provisioning, and the Info.plist

- `project.yml`: add `CODE_SIGN_ENTITLEMENTS: App/Mac/FolinoMac.entitlements` to `FolinoMac`. `CODE_SIGN_STYLE: Automatic` is already inherited from the project-level `settings.base`.
- **`App/Mac/Info.plist` has no `LSApplicationCategoryType`.** The Mac App Store requires it and rejects uploads without it. Add `public.app-category.music`.
- The bundle ID stays `com.KeyNumber.Folino`, shared with iOS, which is what Ⅶ's universal purchase requires.

**One step only the user can take:** the App Store Connect record (app id `6766994527`) has to have the **macOS platform enabled** before any Mac build can be uploaded to it. This is the same record as iOS by design — that is what makes the purchase universal. The plan surfaces it as a gated manual step rather than assuming it.

---

## 5. The release lane

`fastlane/Fastfile` is `platform :ios` only. Add a `platform :mac` block mirroring the three-lane iOS shape, so the two read the same way:

| Lane | Shape |
| --- | --- |
| `archive_and_upload` | `gym(scheme: "FolinoMac", configuration: "Release", export_method: "app-store")` → `.pkg` → `upload_to_app_store(pkg:)`. Same `-skipPackagePluginValidation -skipMacroValidation` xcargs and pinned `derived_data_path` as iOS. |
| `wait_for_build` | The iOS `Spaceship` polling loop, filtered to the macOS platform. |
| `submit` | The iOS lane's shape. |

**No Crashlytics dSYM upload**, unlike the iOS lane: the Mac app composes the no-op crash reporter because there is no Firebase registration for it (§8). Adding the upload step before the registration exists would upload symbols for an app that never reports.

**Integration with the `ios-release` bash tool is out of scope.** That tool is built around `.release.yml`, `App/Resources/VersionHistory.yml`, and iOS release-note authoring. A Mac release driver is worth building when a Mac release is actually being cut; the fastlane lanes are the layer Ⅷ owes.

---

## 6. Mac screenshots

### Why the iOS machinery cannot be reused

`Scripts/capture-screenshots.sh` drives `FolinoScreenshotTests` on an iOS Simulator, with a broker directory that switches the capture into compositor mode and grabs the simulator framebuffer. The capture half of that lives in `ScreenshotKitCapture`, which is UIKit-bound (`HostCompositorCapture.swift`, `ScreenshotCaptureSession.swift`). Porting it is work in the `swift-screenshot-kit` package, and it would be porting a *simulator* mechanism to a platform that has no simulator.

### What Ⅷ does instead

Capture the real Mac window, at a size that is already an App Store size.

1. **A screenshot launch mode in `FolinoMac`** — a launch argument that seeds the library from a fixture, opens a designated score, and sizes the window to exactly **1440 × 900 points**.
2. **`Scripts/capture-mac-screenshots.sh`** — builds once, then launches once per locale with `-AppleLanguages`, waits for the window, and captures with `screencapture -o -l <windowid>`.
3. **No compositing step.** `-o` omits the window shadow, so the PNG is the window's own pixels: **2880 × 1800** on a Retina display, **1440 × 900** on a 1× display. Both are accepted Mac App Store sizes, so the output is deliverable as-is.

Output follows the iOS layout: `fastlane/screenshots/<App Store locale>/<order>_<alias>_<scene>.png`.

**Two constraints this inherits.** `screencapture` needs Screen Recording permission granted to the terminal, and the capture cannot run against a locked screen. Both are named in the QA sheet; neither is automatable.

**The `app-store-screenshots` skill's standing warning applies unchanged:** the capture is not self-verifying, and a run that exits 0 can still have produced wrong pixels. Every delivered shot is inspected before it is used.

---

## 7. Getting a score back out of the Mac app

This is the one behavior change in Ⅷ, and it is here because of §1. Withdrawing origin mirroring rests on "export serves that workflow, one extra action" — **and the Mac has no export.**

The pipeline is complete except for its last inch. `ShareSubmenu` offers the formats, the view models produce the files, and `ScoreShareTarget` carries the resulting URLs; all of it is platform-neutral and compiles for macOS today. What is missing is the presentation: `ActivityViewControllerRepresentable` is `#if os(iOS)` end to end, so on macOS the sheet that would show it is empty. Three `PARITY(macos)` markers already track this — on the representable itself, on `ScoreRowMenu` (row Share and Open in VocalTuner), and on `BulkActionBar` (bulk Share) — and `LibraryRootPresentations` holds the `#else` branch open as "the landing spot for the `NSSharingServicePicker` equivalent when it arrives".

Without it, a score imported on the Mac cannot leave the app by any route: no write-back, no export, no share.

### The Mac form is a save panel, not a share sheet

`NSSavePanel` for one file; a directory chooser for a multi-file selection (bulk share, and the formats that emit more than one file). Not `NSSharingServicePicker`.

The reason is that the two platforms are answering different questions. On iPhone the share sheet *is* the filesystem — Mail, AirDrop and Messages are how a file leaves. On a Mac, "put this where I said" is the primary act and everything downstream is Finder's job; routing it through a sharing service to reach a folder is the long way round. It also fits the presentation the code already has: a sheet driven by `$viewModel.shareTarget`, which a panel can serve and a picker cannot (a picker needs a view anchor, not a presentation).

This is umbrella §8's rule applied as intended — capability does not vary by platform, placement does.

### Shape

- **`UtilityUI`** gains the macOS half beside `ActivityViewControllerRepresentable`: a small presentation that runs the panel on appear, writes the `ScoreShareTarget` URLs to the chosen destination, and dismisses. iOS keeps its call byte-for-byte, in the `GlassEffectCompat` / `PlatformToolbarCompat` house pattern.
- **The `#if os(iOS)` branches** in `LibraryRootPresentations` and Reader's equivalent gain their macOS side.
- **`ScoreRowMenu` and `BulkActionBar`** stop hiding their Share entries on macOS. *Open in VocalTuner* stays hidden — it depends on the cross-app hand-off that is deferred in §8, so its marker is narrowed rather than deleted.
- **Three markers change:** the representable's and the two menu ones are deleted; a narrowed marker for *Open in VocalTuner* replaces part of `ScoreRowMenu`'s.

This touches `UtilityUI`, `ScoreUI`, `Library`, and `Reader` — **not `App/Mac`** — so it does not collide with the parallel library-chooser session's window and scene work.

---

## 8. Out of scope, recorded as future work

Each of these is real work that Ⅷ deliberately does not do. The two that are not already tracked get a `PARITY(macos)` marker so `Scripts/parity-report.py` carries them in `docs/engineering/ios-android-parity.md`.

| Item | Where it is recorded | Why not now |
| --- | --- | --- |
| **Finder document types** — `.mscz` double-click and Open With do not reach folino; only the app's own open panel imports. Needs `CFBundleDocumentTypes` / UTI declarations in `App/Mac/Info.plist` plus an open handler. | **New** `PARITY(macos)` marker on `App/Mac/MacCommands.swift`, next to the open panel it complements. | The open handler lands in the Mac window/scene layer, which the parallel library-chooser session is rewriting. Landing it from here guarantees a merge conflict for a feature that is not on the distribution critical path. |
| **Firebase registration for the Mac app** — no console registration, no Mac `GoogleService-Info.plist`, so Mac crashes never reach Crashlytics and no analytics are recorded. `network.client` (§2) removes the sandbox half of the blocker. | Existing `PARITY(macos)` marker at `App/Shared/AppBootstrap.swift:104`, updated to note that the entitlement is now in place. | Needs a console decision about a Mac app sharing `com.KeyNumber.Folino`, and a build-phase decision about the `upload-symbols` script. Both are independent of getting a signed build out. |

**Also deferred, and not markers:** the three remaining App Group launch tasks — shared-SoundFont reconciliation, the capability stamp, and the cross-app score drain (`App/Mac/SharedContainerTasks.swift`). These stay `nil`. The marker there is rewritten to distinguish two different things it currently lumps together:

- **Permanently not applicable on macOS:** the playlists index and the incoming-share drain. Both exist to serve a Share Extension, and macOS has none. These are not gaps.
- **Deferred gaps:** the other three, which need the App Group entitlement and a `CFBundleURLTypes` declaration for `folino://open-score`.

---

## 9. Verification

Ⅷ produces no new user-visible surface, so its acceptance is mostly mechanical.

**Automated:**

- `Scripts/build-macos-packages.sh` and `Scripts/build-macos-app.sh` stay green.
- **New: `Scripts/check-macos-entitlements.sh`** — builds the Mac app and asserts, via `codesign -d --entitlements :-`, that the three keys from §2 are present in the *built* product. This exists because `project.yml` is regenerated from a file several parallel sessions edit, and a silently dropped `CODE_SIGN_ENTITLEMENTS` would otherwise only surface at upload time. It checks the artifact, not the spec file.
- `FolinoMacTests` (19 tests) stay green. Note the standing trap: they report "hung before establishing connection" whenever the screen is locked.
- Reader / Editor / Library / FolinoTests package suites stay green — the sandbox change should not touch them, and a failure means it did.

**By hand (QA sheet):**

- The sandboxed app launches, and the library is empty (the container is new). This is the expected result of §3, not a bug.
- Import through File ▸ Open works, the score renders, and it survives a relaunch.
- Export through the save panel writes where the user chose.
- The high-quality SoundFont download completes — the direct test of `network.client`.
- Playback works. **Release build**, per the standing rule that a Debug Mac build's playback is unrepresentative.
- A screenshot run produces PNGs at 2880 × 1800 (or 1440 × 900), and they are inspected rather than trusted.

---

## 10. Documents this revises

- **`2026-08-31-macos-app-design.md` §1** — the origin-mirroring paragraph is replaced with the withdrawal and its reasoning (§1 above). §9's Ⅷ row loses "security-scoped bookmark persistence". §10 gains this document's own entry.
- **`docs/engineering/ios-android-parity.md`** — regenerated, not edited, from the marker changes in §7 (three share markers retired or narrowed) and §8 (one new marker; the `SharedContainerTasks` marker rewritten).
