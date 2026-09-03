# macOS distribution QA

## 0. Blocker — the sandboxed app crashes ~3 seconds after every launch

**Every interactive item on this sheet is unrunnable until this is fixed. Read this section before working
through the rest of the list, or you will spend time wondering why the app never shows a window.**

The sandboxed Mac app crashes on the unconditional startup path `AppBootstrap.start()` →
`installAudioStack()` → `AudioStackFactory.make()` → `LivePlaybackController.init` → `PlaybackEngine.init` →
`SoftClipAudioUnit.makeNode()`. It is a `SIGTRAP` / uncaught `NSException` from
`AVAudioUnitEffect.init(audioComponentDescription:)`, reason `error -3000`, and it is deterministic — it
happens on every launch, not intermittently.

**Root cause, confirmed by a controlled 2×2 bench (one variable per trial), not guessed:**

| Sandboxed | `componentFlags` | Result |
| --- | --- | --- |
| yes | `0` | crash, `error -3000` |
| yes | `sandboxSafe` | success |
| no | `0` | success |
| no | `sandboxSafe` | success |

`swift-sheet-music`'s `Sources/SheetMusicAudioApple/SoftClipAudioUnit.swift` declares `componentFlags: 0`. A
locally registered `AudioComponent` must carry `kAudioComponentFlag_SandboxSafe` to be instantiable from a
sandboxed host — the file's own comment ("all `AVAudioUnitEffect` needs") is true unsandboxed and false
inside the sandbox. **This is not a defect of this sub-project.** The App Sandbox entitlements themselves
(Section 3 below) are correct and pass `Scripts/check-macos-entitlements.sh`; they are simply not enough to
make the app launch, because a separate, pinned dependency crashes first.

A one-line fix (`componentFlags: AudioComponentFlags.sandboxSafe.rawValue`) has been **requested of the
session that owns `swift-sheet-music`**. **folino's `ssm` version pin is not to be moved ahead of that fix
landing** — bumping it speculatively would trade a known-bad pin for an unverified one.

**What this means for you:** before starting Sections 4–6, launch the built app once and confirm it does
not crash in the first ~5 seconds. If it still crashes, stop — there is nothing further to check, and a
report of "nothing opened" is not a new finding, it is this one. If it does not crash, the fix has landed
(check whether the `ssm` pin moved since this sheet was written) and you can proceed through the rest of
this sheet normally.

---

## Prerequisites only the account holder can do

1. **Enable the macOS platform on the App Store Connect record** (app id `6766994527`, `com.KeyNumber.Folino`).
   The Mac app shares the iOS record by design — that is what makes Ⅶ's purchase universal — but the macOS
   platform has to be added to it before any `.pkg` will upload.
2. **A Mac Installer Distribution certificate.** A Mac App Store `.pkg` is signed with a different certificate
   from the app-signing one. Whether `-allowProvisioningUpdates` mints it automatically is UNVERIFIED; the first
   `fastlane mac archive_and_upload` is what settles it. If it fails, create it in the Developer portal.

---

## 2. Before you start

- **Unlock the screen.** Hosted Mac tests (`FolinoMacTests`) report "the test runner hung before establishing
  connection" while the screen is locked — this is `testmanagerd` stalling, not a test failure, and killing it
  does not help; only unlocking does.
- **Grant Screen Recording permission to the terminal app you run `screencapture` from.** Without it,
  screenshot capture fails, and macOS re-prompts for this periodically even after it has been granted once —
  if a capture run that previously worked suddenly produces nothing, check this first before suspecting the
  script.
- **The capture cannot run against a locked screen either.** Same root cause as the hosted-test hang above.
- Build a fresh copy of the app (`Scripts/build-macos-app.sh`, or `xcodebuild -scheme FolinoMac`) before
  starting — `check-macos-entitlements.sh` and the sandbox items below both need the current entitlements
  baked into the artifact, not a stale one from an earlier session.

---

## 3. Sandbox acceptance

- **The app launches at all.** This is Task 1's actual acceptance test, not a formality: `prepareDirectories()`
  throws into `failure` if the SoundFont directory cannot be created (`AppBootstrap.swift`), so a regression in
  the sandbox/SoundFont wiring shows up as **a broken app that never shows a window**, not as a missing
  SoundFont or a silent feature gap. (Blocked today by Section 0 — confirm that is resolved first.)

- **The library is empty, and every Mac setting has reset to its default.** This is the expected result of
  moving the container, not a bug, and not data loss. Three locations stopped being read the moment the app
  became sandboxed:
  - `~/Library/Application Support/folino/` — the pre-sandbox library and its SQLite database.
  - `~/Library/Group Containers/group.com.KeyNumber.shared/Soundfonts/` — any high-quality SoundFont
    downloaded before this sub-project (it lived in a group container the unsandboxed app could reach without
    holding the App Group entitlement; see Section 3's code fix below).
  - `~/Library/Preferences/com.KeyNumber.Folino.plist` — **every** `UserDefaults` setting (per-instrument
    mixer levels, per-score playback prefs, onboarding flags, everything), which now lives in the sandbox
    container's own `Preferences`.

    Nothing was deleted from any of the three. They simply stopped being on the path the sandboxed app is
    allowed to read. **If you want a test library worth keeping, copy it in by hand** before or after first
    launch:

    ```sh
    cp -R ~/Library/Application\ Support/folino \
      ~/Library/Containers/com.KeyNumber.Folino/Data/Library/Application\ Support/folino
    ```

    (Quit the app first if it is running, so it is not writing to the destination mid-copy.)

- **Import through File ▸ Open**, then relaunch and confirm the score is still there. This exercises the
  `NSOpenPanel` / Powerbox route the `files.user-selected.read-write` entitlement exists for. Three ways this
  can fail look alike from the outside but point at different layers, so separate them before reporting one:
  **the panel never appears** — Powerbox presents the panel on the app's behalf regardless of the sandbox, so
  this is a command-wiring problem, not an entitlement one; **the panel appears, you pick a file, and nothing
  shows up in the library with no error** — that is the shape of a denied read, i.e. the entitlement; **the
  panel appears, a file is chosen, and folino shows an import-error alert** — that is the parser rejecting the
  file, not the sandbox, since a visible error is proof the bytes were readable in the first place.

- **Drag-and-drop import from Finder.** `MacLibraryBrowser.swift:95` has its own `.dropDestination(for:
  URL.self)` — this is a **second, independent** import route. It reaches the sandbox through a pasteboard
  drag-and-drop extension rather than through the open panel's Powerbox path, so passing the File ▸ Open test
  above does **not** mean this one also works — it is a different code path with its own sandbox exception,
  and a regression here would not be caught by only testing the menu command.

- **Trigger the high-quality SoundFont download explicitly**, from Settings. Do not rely on it starting on its
  own: the auto-download session uses `allowsCellularAccess = false`
  (`LiveMuseScoreGeneralProvider.swift`), so on a Mac connected over Ethernet rather than Wi-Fi it will not
  auto-start. **If you see nothing happen, that is very likely this Wi-Fi requirement, not a
  `com.apple.security.network.client` entitlement failure** — the two look identical from the user's side
  (nothing downloads), but only one of them is fixed by touching the entitlements file. Confirm the SoundFont
  lands under `~/Library/Containers/com.KeyNumber.Folino/Data/Library/Application Support/Soundfonts/`
  (inside the container — not the old group-container path, which the Mac no longer reads at all now that
  `AppPaths.sharedContainer` returns `nil` on macOS).

- **Playback works, on a Release build.** This is the project's standing rule
  (`feedback_macos_qa_release_build`), not a preference specific to this sheet: a Debug Mac build's playback is
  unrepresentative because `swifty-synth` is unoptimized there, and a real audio glitch could be mistaken for
  a Debug-only artifact, or a Debug-only sluggishness could be mistaken for a real regression.

---

## 4. Export acceptance

Confirm first, everywhere below: the macOS copy reads **Export…** (`scoreUI.share.export.action` /
`reader.export.action`), never "Share" — the underlying capability is the same pipeline as iOS's share sheet,
but the Mac presentation is a save panel / folder chooser, and a leftover "Share" label would be a real bug,
not a wording nit, since it promises a sheet the Mac never shows.

For each of the four entry points below: the file lands where you chose in the panel, with the name you'd
expect from the score title and format, and it opens correctly in an external app (Preview for PDF, MuseScore
or a text editor for MusicXML, etc.).

- **From a library row** — right-click a score, or its row menu (`ScoreRowMenu`) → **Export…** → pick a
  format. Expect a **save panel** for a single-file format.
- **From a bulk selection of two scores** — select two rows, use the bulk action bar / bulk context menu
  (`BulkActionBar`) → **Export…** → pick a format. **Expect a folder chooser, not a save panel** — this is the
  multi-item overload of `.fileExporter`, and if a save panel appears instead for two items, that is the
  single-item overload firing on the wrong binding, a real defect.
- **From the score window's toolbar** — open a score, use the toolbar's Export menu (`square.and.arrow.up`,
  primary-action placement in `MacReaderRootScreen`) → pick a format. This is a separate code path from the
  library-row export (a different `.scoreExportPresentation(target:)` binding on a different screen), so
  passing the library-row test does not imply this one passes.
- **For a PDF-backed score** — import a PDF, then export it. PDF-backed scores expose extra formats
  (`scoreUI.format.pdf.annotated`, `scoreUI.format.originalPDF.annotated`) that a non-PDF score never offers;
  this exercises the annotated-original-PDF path specifically, which the other three checks above cannot,
  since they can all be run against an `.mscz`/`.musicxml` score that never touches that code.

**What a failure here would be mistaken for:** an empty save panel, or no panel at all, looks identical
whether the cause is (a) the `.fileExporter` binding never firing, (b) the sandbox's `files.user-selected.
read-write` entitlement missing from the build (check with `check-macos-entitlements.sh` first — it is cheap
and rules out the whole sandbox layer in one command), or (c) the export item producing zero files upstream
in the view model. Check the entitlement gate before assuming the SwiftUI wiring is at fault.

---

## 5. Screenshots

**This section is blocked, separately from Section 0.** The Mac screenshot target (`FolinoMacScreenshot`,
`Scripts/capture-mac-screenshots.sh`) has not been built yet — it is deferred behind the Section 0 crash,
since the capture script launches the built app and photographs its window, which cannot succeed while the
app crashes on launch. Skip this section until that target exists and a capture run has actually been
attempted; do not treat its absence today as a finding to re-report.

Once a capture run exists:

- **Every delivered PNG is exactly 2880×1800 (Retina) or 1440×900 (1×) — no other size.** The capture sizes the
  window by *frame*, not content, specifically to land on these two accepted App Store sizes; anything else
  means the frame-vs-content-area distinction broke.
- **No alpha channel on any PNG.** `screencapture -o` drops the window shadow but leaves the window's rounded
  corners as transparent pixels; the flattening step is supposed to composite those onto an opaque background.
  A PNG that still carries alpha will often *look* fine in a quick glance — the transparency only becomes
  visible once App Store Connect (or an image inspector) checks the channel — so check with a tool
  (`sips -g hasAlpha <file>`, or `file`/`identify`), not by eye alone.
- **Every PNG is actually opened and looked at, not just measured.** This is the standing warning from the
  `app-store-screenshots` skill, restated because it applies unchanged here: **a capture run that exits 0
  proves nothing about the pixels.** A wrong locale string, a crashed-mid-scene blank window, or a fixture
  library that failed to seed can all produce a correctly-sized, alpha-free PNG that is still the wrong
  screenshot. Exit code and dimensions are necessary checks, not sufficient ones.

---

## 6. Not verified by this sheet, and why

- **Actual App Store upload / submission.** Blocked on personal cloud sync (Ⅵb / SP2) shipping first — the
  umbrella spec makes that a prerequisite for shipping macOS at all, independent of anything in this
  sub-project. `fastlane mac archive_and_upload` / `submit` exist and parse, but running them is out of scope
  here and was not attempted.
- **Crashlytics on the Mac app.** There is no Firebase console registration for the Mac target and no Mac
  `GoogleService-Info.plist`, so the app composes the no-op crash reporter — nothing to verify yet. (Note this
  is independent of, and does not explain, the Section 0 crash: that one happens before Firebase's reporting
  path would even matter, and would not be caught by Crashlytics regardless.)
- **Finder double-click / Open With.** `.mscz` files opened directly from Finder do not reach folino yet — no
  `CFBundleDocumentTypes` declaration, no open handler. Deliberately deferred; tracked by a `PARITY(macos)`
  marker on `App/Mac/MacCommands.swift`.
- **File ▸ Export… in the menu bar.** Export is reachable today from library rows and the score window's
  toolbar, but not from the menu bar, which is the Mac-idiomatic home for it. Deferred because
  `App/Mac/MacCommands.swift` is being rewritten by a parallel session; landing it from here would have
  guaranteed a merge conflict for a feature that is not on the distribution critical path. Tracked by a
  `PARITY(macos)` marker beside the export affordance in the Reader package.
