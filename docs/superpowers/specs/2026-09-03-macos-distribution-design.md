# folino for macOS — Sub-project Ⅷ, Distribution

**Date:** 2026-09-03
**Status:** Approved direction. Implementation plan to follow.
**Umbrella spec:** `2026-08-31-macos-app-design.md` §9, row Ⅷ. Depends on Ⅲb only.
**Scope:** What it takes to put the Mac app in front of a user — the App Sandbox it must run inside (and the one path that would break it, §2), the signing and provisioning that go with it, a release lane, Mac screenshots, and the one behavior gap that withdrawing origin mirroring exposes: the Mac cannot export a score at all (§7).

Shipping is **not** in scope. §1 of the umbrella spec makes personal cloud sync (Ⅵb / SP2) a prerequisite for *shipping* macOS, and that is unchanged. Ⅷ ends when a signed, sandboxed build can be produced and uploaded to TestFlight; the decision to submit is the user's, later.

---

## 1. The umbrella spec's origin mirroring is withdrawn

Ⅷ was written to carry "App Sandbox + security-scoped bookmark persistence (what §1's origin mirroring actually requires)". **Origin mirroring is withdrawn**, permanently, and the bookmark persistence goes with it. `2026-08-31-macos-app-design.md` §1 is amended in the same commit as this spec.

### What was proposed

An imported score would remember its *origin* — a security-scoped bookmark to the file it came from — and mirror every save back to it. On by default, switchable per score. The stated purpose was to pay the one cost of not being a document-based app: "receive an `.mscz` over Drive/AirDrop, edit it, send it back" becomes open → edit → export rather than open → edit → ⌘S.

### Why it is withdrawn

**It reintroduces exactly the split §1 rejected MuseScore 4 for.** §1's case against a document model is that MuseScore 4 bolted the cloud onto local documents and now carries a permanent two-place split (Save / Save online / Save to cloud). Mirroring gives folino the same shape: a library item, plus a file on disk that can diverge from it. §1 presents the origin as write-only ("the library stays the single truth; the origin is only a write target"), but a file that exists on disk can be edited by anything — MuseScore, a sync client, the user. The moment it is, folino owes an answer to "which one wins", which is a conflict-resolution design nobody asked for.

**It is a platform split, not a per-score attribute.** §1 argued that making origin a per-score attribute avoids splitting the experience into two modes (`feedback_no_experience_divergence`). It avoids the mode split and introduces a platform split instead. Not because the other platforms *cannot* hold a durable reference — iOS has `bookmarkData()` on a document-picker URL and Android has `takePersistableUriPermission` — but because **folino's import routes are one-shot by construction**: `.onOpenURL`, the Share Extension, and AirDrop deliver a URL whose scope dies with the call, which is exactly why `LiveScoreFileImporter.prepareImport` stages a copy rather than keeping the URL (`LiveScoreFileImporter.swift:40-42`). Only a file the user explicitly picked in a panel could carry an origin, and on iPhone and Android that is the minority route. "Editing on the Mac also updates the original file, editing on the iPad usually does not" is the least explicable kind of difference — and "usually" is worse than "never".

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

### The one thing that is not where it looks like it is: the SoundFont directory

`AppPaths.soundfontsDirectory` is `sharedSoundfontsDirectory ?? legacySoundfontsDirectory` (`App/Shared/AppPaths.swift:70-71`), and its comment says the shared half is `nil` when the entitlement is missing. **That is the iOS rule, and macOS does not follow it.** An unsandboxed Mac app gets a real path back from `containerURL(forSecurityApplicationGroupIdentifier:)` whether or not it holds the entitlement, and the directory is created on demand.

Measured on this machine, 2026-09-03:

```
~/Library/Group Containers/group.com.KeyNumber.shared/Soundfonts/consumers/com.KeyNumber.Folino
~/Library/Application Support/Soundfonts                                     ← does not exist
```

So the Mac's SoundFonts already live in a group container, not in Application Support, and the writer is shared code that runs on every platform: `AudioStackFactory.swift:41-42` hands `AppPaths.soundfontsDirectory` to `SharedSoundfontReclaimer`. `App/Mac/SharedContainerTasks.swift` declining all five launch tasks does not cover this path.

**Why that is a launch-blocker rather than a degraded feature.** `AppBootstrap.prepareDirectories()` creates that directory with `try`, not `try?` (`AppBootstrap.swift:293-294`), and a throw lands in `failure = error` (`AppBootstrap.swift:165`) — a failed startup, not a missing SoundFont. Once the app is sandboxed without an App Groups entitlement, the behavior of that call is Apple's to decide and ours to not depend on.

**The fix, and it is a real code change: `AppPaths.sharedContainer` returns `nil` on macOS.** One `#if os(macOS)` in one computed property. It makes the Mac's behavior deterministic instead of resting on an undocumented quirk, it puts SoundFonts back under Application Support where §3's relocation argument actually applies, and it says by construction what `SharedContainerTasks` already says by construction: **the Mac does not participate in the App Group.** When a future sub-project wires the cross-app tasks (§8), it removes this alongside adding the entitlement — the two belong together.

### Nothing else is gated by the sandbox

Audio playback is output-only (no `device.audio-input`). With the change above, the library, the database, the staging directory, and the SoundFont directory are all under Application Support, which the sandbox relocates transparently (§3). No temporary-exception entitlement is needed anywhere.

---

## 3. The library moves into the container

`AppPaths.documentsRoot` resolves `.applicationSupportDirectory` on macOS and appends `folino/`. For a sandboxed app, `FileManager` resolves that same call inside the container — `~/Library/Containers/com.KeyNumber.Folino/Data/Library/Application Support/folino/` — so the database, the scores directory, the staging directory, and `legacySoundfontsDirectory` all move together, **with no change at any of those call sites.** The one code change the relocation needs is §2's `sharedContainer` fix, which is what brings SoundFonts under this argument in the first place.

The `PARITY(macos)` marker at `App/Shared/AppPaths.swift:6` is therefore **deleted**, not implemented. Its own prediction was right: "Application Support is already where that container's equivalent maps, so nothing here has to move twice in spirit."

**Pre-sandbox development data is abandoned, deliberately.** Three directories stop being visible to the app: `~/Library/Application Support/folino/` (library and database), `~/Library/Group Containers/group.com.KeyNumber.shared/Soundfonts/` (any downloaded high-quality SoundFont — see §2), and `~/Library/Preferences/com.KeyNumber.Folino.plist` (**every `UserDefaults` setting**, which moves to the container's own `Preferences`). Nothing is deleted; it stops being read. There are no macOS users, so a migration path would be code that never runs in production and has to be maintained forever. The QA sheet records the by-hand copy for a test library worth keeping, and warns that Mac settings reset once.

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
| `archive_and_upload` | `gym(scheme: "FolinoMac", configuration: "Release", export_method: "app-store")` → `.pkg` → `upload_to_app_store(pkg: lane_context[SharedValues::PKG_OUTPUT_PATH], platform: "osx")`. Same `-skipPackagePluginValidation -skipMacroValidation` xcargs and pinned `derived_data_path` as iOS. |
| `wait_for_build` | The iOS `Spaceship` polling loop, **filtered on `pre_release_version.platform == "MAC_OS"`**. |
| `submit` | The iOS lane's shape, with `platform: "osx"`. |

**Four places where "mirror the iOS lane" is not enough**, each of which fails quietly rather than loudly:

- **`upload_to_app_store` defaults to `platform: "ios"`.** Omitting it uploads a Mac `.pkg` against the iOS platform of the same app record.
- **`before_all` is scoped per `platform` block.** The `app_store_connect_api_key` call at `Fastfile:3-12` lives inside `platform :ios` and does not carry over; the `:mac` block needs its own.
- **`CURRENT_PROJECT_VERSION` is project-wide** (`project.yml:13`), so the same version+build string exists on both platforms of one app record. An unfiltered `wait_for_build` will happily report the *iOS* build as ready. (Sharing the number is otherwise fine — build numbers are scoped per platform.)
- **`fastlane/metadata` is shared.** The iOS `submit` lane would push iOS release notes onto the Mac version and vice versa. The plan picks: separate metadata directories, or Mac metadata entered by hand in App Store Connect for now.

**A second step only the user can take.** Beyond enabling the macOS platform (§4), a Mac App Store `.pkg` is signed with a **Mac Installer Distribution** certificate, which is a different certificate from the app-signing one. Whether `-allowProvisioningUpdates` mints it automatically is unverified; the plan treats it as a gated manual step and confirms on the first archive.

**No Crashlytics dSYM upload**, unlike the iOS lane: the Mac app composes the no-op crash reporter because there is no Firebase registration for it (§8). Adding the upload step before the registration exists would upload symbols for an app that never reports.

**Integration with the `ios-release` bash tool is out of scope.** That tool is built around `.release.yml`, `App/Resources/VersionHistory.yml`, and iOS release-note authoring. A Mac release driver is worth building when a Mac release is actually being cut; the fastlane lanes are the layer Ⅷ owes.

---

## 6. Mac screenshots

### Why the iOS machinery cannot be reused

`Scripts/capture-screenshots.sh` drives `FolinoScreenshotTests` on an iOS Simulator, with a broker directory that switches the capture into compositor mode and grabs the simulator framebuffer. The capture half of that lives in `ScreenshotKitCapture`, which is UIKit-bound (`HostCompositorCapture.swift`, `ScreenshotCaptureSession.swift`). Porting it is work in the `swift-screenshot-kit` package, and it would be porting a *simulator* mechanism to a platform that has no simulator.

### What Ⅷ does instead

Capture the real Mac window at a size that is already an App Store size.

1. **A separate `FolinoMacScreenshot` target**, not a mode inside `FolinoMac`. It mirrors what the iOS side already does and for the reasons `project.yml:308-314` records: a distinct `PRODUCT_BUNDLE_IDENTIFIER` (`com.KeyNumber.Folino.screenshot`) and its own product name. On macOS that separation buys something iOS does not even need — **a different bundle ID means a different sandbox container**, so seeding a fixture library cannot overwrite the real one, and neither the fixture `.mscz` nor a "replace the library" launch argument is compiled into the shipping binary.
2. **The window is sized by frame, not by content.** `screencapture -l` captures the window *frame*, title bar included, so a 1440 × 900 **content** area yields roughly 1440 × 928 — off the accepted list. The screenshot target sets the frame with `NSWindow.setFrame`, and the capture script asserts the delivered pixel dimensions rather than trusting them.
3. **`Scripts/capture-mac-screenshots.sh`** — builds once, then launches once per locale with `-AppleLanguages`, polls `CGWindowListCopyWindowInfo` until the window exists, and captures with `screencapture -o -l <windowid>`.
4. **One compositing step, not zero.** `-o` drops the shadow but **the window's rounded corners stay as transparent pixels**, and App Store Connect rejects screenshots with an alpha channel. The script flattens onto an opaque background as its last step. Everything else is free: the flattened PNG is **2880 × 1800** on a Retina display and **1440 × 900** on a 1× display, both accepted sizes, with no scaling or canvas placement.
5. **Output goes to `fastlane/screenshots-mac/<App Store locale>/`**, not the iOS directory. The iOS `submit` lane passes `screenshots_path` wholesale with `overwrite_screenshots: true` (`Fastfile:128-131`); sharing one tree means each platform's upload sweeps up the other's PNGs.

The per-file naming follows the iOS convention: `<order>_<alias>_<scene>.png`.

**Three constraints this inherits.** `screencapture` needs Screen Recording permission granted to the terminal — and macOS re-prompts for it periodically. The capture cannot run against a locked screen. And the display must be at least 1440 × 900 points, which rules out capturing on a small external monitor. All three are named in the QA sheet; none is automatable.

**The `app-store-screenshots` skill's standing warning applies unchanged:** the capture is not self-verifying, and a run that exits 0 can still have produced wrong pixels. Every delivered shot is inspected before it is used.

---

## 7. Getting a score back out of the Mac app

This is the one behavior change in Ⅷ, and it is here because of §1. Withdrawing origin mirroring rests on "export serves that workflow, one extra action" — **and the Mac has no export.**

The pipeline is complete except for its last inch. `ShareSubmenu` offers the formats, the view models produce the files, and `ScoreShareTarget` carries the resulting URLs; all of it is platform-neutral and compiles for macOS today. What is missing is the presentation: `ActivityViewControllerRepresentable` is `#if os(iOS)` end to end, so on macOS the sheet that would show it is empty. Three `PARITY(macos)` markers already track this — on the representable itself, on `ScoreRowMenu` (row Share and Open in VocalTuner), and on `BulkActionBar` (bulk Share) — and `LibraryRootPresentations` holds the `#else` branch open as "the landing spot for the `NSSharingServicePicker` equivalent when it arrives".

Without it, a score imported on the Mac cannot leave the app by any route: no write-back, no export, no share.

### The Mac form is a save panel, not a share sheet

A save panel for one file; a folder chooser for a multi-file selection (bulk share, and the formats that emit more than one file). Not `NSSharingServicePicker`.

The two platforms are answering different questions. On iPhone the share sheet *is* the filesystem — Mail, AirDrop and Messages are how a file leaves. On a Mac, "put this where I said" is the primary act and everything downstream is Finder's job; routing it through a sharing service to reach a folder is the long way round.

**And the label changes with it.** "Share ▸ PDF" opening a save panel is a mismatch, so the macOS entries read **Export…**. Umbrella §8 asks exactly this: capability does not vary by platform, placement and wording do.

### Use `.fileExporter`, not a hand-rolled representable

`.fileExporter(isPresented:items:contentTypes:onCompletion:)` is macOS 14+ / iOS 17+, comfortably under the repo's macOS 15 / iOS 18 floors. Given `[URL]` — which is `Transferable` — it presents a save panel for one item and a folder chooser for several, which is precisely the behavior described above. No `UtilityUI` representable is needed, and `isPresented` is a `Binding` derived from `shareTarget != nil`.

The alternative — a `.sheet` whose content runs `NSSavePanel` on appear — is worse on macOS specifically: a SwiftUI sheet there is a **visible** window-modal sheet, so the user would see an empty panel slide down with the save panel stacked on top of it.

One thing the plan verifies by spike before building on it: whether `.fileExporter`'s default filename for a `URL` item comes from `lastPathComponent`. If it does not, the exported files land with wrong names and the plan falls back to `NSSavePanel` driven from an `NSViewRepresentable` anchor.

### Where the entry points go

- **Library** — `ScoreRowMenu:58` and `BulkActionBar:70` stop hiding their Share entries on macOS, relabeled Export…; `LibraryRootPresentations:186-197` swaps its `#else EmptyView()` for the exporter.
- **The Mac score window** — **there is no `#if` to fill here.** `ReaderRootScreen.swift` is wrapped in `#if os(iOS)` from line 15 to the end of the file, so its `.sheet(item: $viewModel.shareTarget)` does not exist on macOS at all. The Mac's reader is a sibling, `MacReaderRootScreen`, whose own marker says the share controls "are still iOS-only" (`Screens/Mac/MacReaderRootScreen.swift:8`) — it already receives a `ScoreShareService` (`:75`) and simply never offers it. **Ⅷ adds the affordance to the Mac reader's own chrome**, inside the `Reader` package.
- **Not the menu bar.** File ▸ Export… is the Mac-idiomatic home, and it lives in `App/Mac/MacCommands.swift` — the layer the parallel library-chooser session is rewriting. It is deferred to a `PARITY(macos)` marker rather than fought over. The toolbar affordance makes export reachable in the meantime; the menu command is placement, not capability.
- **Markers:** `ActivityViewControllerRepresentable`'s and `BulkActionBar`'s are deleted. `ScoreRowMenu`'s and `MacReaderRootScreen`'s are **narrowed**, not deleted — *Open in VocalTuner* still depends on the cross-app hand-off deferred in §8, and the Mac reader's inspectors and score ⇄ original-PDF switch are still missing. A new marker records the deferred File ▸ Export… command.

This touches `UtilityUI`, `ScoreUI`, `Library`, and `Reader` — **not `App/Mac`** — which is what keeps it clear of the parallel session.

### One caveat the withdrawal argument owes this section

§1's third reason is that folino's re-encode drops archive entries it does not model. **That is equally true of this export** — a user who picks the original file in the save panel does the same damage. The difference is consent: an overwrite the user navigated to and confirmed is not a default that fires on every autosave. Whether the fidelity warning §1 imagined for *Overwrite Original…* should also appear here is left to the plan's copy review; it is a warning, not a mechanism.

---

## 8. Out of scope, recorded as future work

Each of these is real work that Ⅷ deliberately does not do. The ones not already tracked get a `PARITY(macos)` marker so `Scripts/parity-report.py` carries them in `docs/engineering/ios-android-parity.md`.

| Item | Where it is recorded | Why not now |
| --- | --- | --- |
| **Finder document types** — `.mscz` double-click and Open With do not reach folino; only the app's own open panel imports. Needs `CFBundleDocumentTypes` in `App/Mac/Info.plist` plus an open handler. | **New** `PARITY(macos)` marker on `App/Mac/MacCommands.swift`, next to the open panel it complements. | The open handler lands in the Mac window/scene layer, which the parallel library-chooser session is rewriting. Landing it from here guarantees a merge conflict for a feature that is not on the distribution critical path. |
| **File ▸ Export…** — the menu-bar home for §7's export, which Ⅷ reaches only from the Library rows and the Mac reader's chrome. | **New** `PARITY(macos)` marker alongside the export affordance in `Reader`. | Same reason: `App/Mac/MacCommands.swift` belongs to the parallel session right now. |
| **Firebase registration for the Mac app** — no console registration, no Mac `GoogleService-Info.plist`, so Mac crashes never reach Crashlytics and no analytics are recorded. `network.client` (§2) removes the sandbox half of the blocker. Note that `FirebaseAnalytics` and `FirebaseCrashlytics` are already **linked into the Mac binary** through `Packages/Infrastructure/Package.swift:77,85` — the no-op composition is at the call site, not at the link line. | Existing `PARITY(macos)` marker at `App/Shared/AppBootstrap.swift:104`, updated to note that the entitlement is now in place. | Needs a console decision about a Mac app sharing `com.KeyNumber.Folino`, and a build-phase decision about the `upload-symbols` script. Both are independent of getting a signed build out. |

**Two plist items that are cheap enough to reconsider during the plan**, both touching only `App/Mac/Info.plist` and `project.yml` — never the scene layer — so neither risks the conflict that defers the rows above:

- **`UTImportedTypeDeclarations`.** The iOS `Info.plist` declares `org.musescore.mscz` and friends (`App/Info.plist:135-`); the Mac plist declares nothing, so `ScoreFileTypes.allowed` resolves through `dyn.*` types on macOS. It works, but it is accidental. The declarations are independent of the open handler above.
- **`PrivacyInfo.xcprivacy`** is in the `Folino` target's sources and not in `FolinoMac`'s. Required-reason API enforcement is iOS-family only, but the privacy label is a property of the shared app record.

**Also deferred, and not markers:** the three remaining App Group launch tasks — shared-SoundFont reconciliation, the capability stamp, and the cross-app score drain (`App/Mac/SharedContainerTasks.swift`). These stay `nil`. The marker there is rewritten to distinguish two different things it currently lumps together:

- **Permanently not applicable on macOS:** the playlists index and the incoming-share drain. Both exist to serve a Share Extension, and macOS has none. These are not gaps.
- **Deferred gaps:** the other three, which need the App Group entitlement and a `CFBundleURLTypes` declaration for `folino://open-score`.

---

## 9. Verification

Ⅷ produces no new user-visible surface, so its acceptance is mostly mechanical.

**Automated:**

- `Scripts/build-macos-packages.sh` and `Scripts/build-macos-app.sh` stay green.
- **New: `Scripts/check-macos-entitlements.sh`** — builds the Mac app and asserts, via `codesign -d --entitlements - --xml`, that the three keys from §2 are present in the *built* product. (`--entitlements :-` emits the legacy blob-header format; `--xml` is what parses.) This exists because `project.yml` is regenerated from a file several parallel sessions edit, and a silently dropped `CODE_SIGN_ENTITLEMENTS` would otherwise only surface at upload time. It checks the artifact, not the spec file. Baseline measured 2026-09-03: the built app carries `get-task-allow` and nothing else, so this check fails today and passes after Task 1 — which is what makes it a real gate rather than a tautology.
- `FolinoMacTests` (19 tests) stay green. Note the standing trap: they report "hung before establishing connection" whenever the screen is locked.
- Reader / Editor / Library / FolinoTests package suites stay green — the sandbox change should not touch them, and a failure means it did.

**By hand (QA sheet):**

- The sandboxed app **launches at all.** This is the §2 SoundFont fix's real acceptance test: `prepareDirectories()` throws into `failure` if the SoundFont directory cannot be created, so a regression here shows up as a broken app, not a missing feature.
- The library is empty, and Mac settings have reset to defaults. Both are the expected result of §3, not bugs.
- Import through File ▸ Open works, the score renders, and it survives a relaunch.
- **Drag-and-drop import from Finder** still works — `MacLibraryBrowser.swift:95` has a `.dropDestination(for: URL.self)`, which is a second import route reaching the sandbox through a different mechanism (pasteboard extension) than the open panel.
- Export writes where the user chose, from both a library row and the Mac score window, and for a multi-file format.
- The high-quality SoundFont download completes. **Trigger it explicitly**: the auto-download requires Wi-Fi (`LiveMuseScoreGeneralProvider.swift:140-145`, `allowsCellularAccess = false`), so a wired Mac never starts it on its own and a "nothing happened" result would be misread as a `network.client` failure.
- Playback works. **Release build**, per the standing rule that a Debug Mac build's playback is unrepresentative.
- A screenshot run produces PNGs at exactly 2880 × 1800 (or 1440 × 900) **with no alpha channel**, and they are inspected rather than trusted.

---

## 10. Documents this revises

- **`2026-08-31-macos-app-design.md` §1** — the origin-mirroring paragraph is replaced with the withdrawal and its reasoning (§1 above). §9's Ⅷ row loses "security-scoped bookmark persistence". §10 gains this document's own entry.
- **`docs/engineering/ios-android-parity.md`** — regenerated, not edited, from the marker changes in §3 (`AppPaths`'s marker deleted), §7 (four share markers retired or narrowed), and §8 (two new markers; the `SharedContainerTasks` and `AppBootstrap` markers rewritten).

---

## 11. Reviewed against the repository

This spec was reviewed on 2026-09-03 against the working tree, and five of its claims did not survive. They are corrected above rather than footnoted, but the corrections are worth knowing about, because each was the kind of plausible statement a plan would have been built on:

1. **The SoundFont directory was not under Application Support on macOS** — it is in a group container the unsandboxed Mac app created without holding the entitlement, and the writer is shared code. §2.
2. **"No code changes" was false** — §2's `sharedContainer` fix is one, and it is the difference between a working launch and a failed one.
3. **`ReaderRootScreen` has no macOS half to fill in** — the whole file is `#if os(iOS)`, so the Mac score window needs a new affordance rather than an `#else`. §7.
4. **The screenshot output needed a compositing step after all** — rounded corners leave an alpha channel that App Store Connect rejects — and the capture had to move to its own target and its own output directory. §6.
5. **The platform-split argument was overstated** — iOS and Android *can* hold durable references; what they cannot do is carry an origin through folino's one-shot import routes. §1.

Areas the review could not settle from the repository, and which the plan therefore verifies by spike or on the first upload: the sandboxed return value of `containerURL(forSecurityApplicationGroupIdentifier:)` (§2 removes the dependency rather than betting on it), whether `-allowProvisioningUpdates` mints a Mac Installer Distribution certificate (§5), and `.fileExporter`'s default filename for a `URL` item (§7).
