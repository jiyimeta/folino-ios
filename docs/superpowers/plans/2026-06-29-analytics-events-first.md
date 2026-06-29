# Analytics Events-First Migration — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Re-align Folino's existing (unreleased) Firebase Analytics to the events-first policy: zero user properties, raw numeric params, plus `screen_view` / `settings_snapshot` / `library_snapshot` events and session-aggregated annotation.

**Architecture:** Keep all plumbing (the `Analytics` protocol + `NoopAnalytics`, the value types, the typed-factory pattern, the consent gate, Firebase isolation in Infrastructure). Change only the *taxonomy*: move every analysis-only user property into launch events, stop bucketing at collection (log raw ints), aggregate per-stroke annotation into a session-end event, and add manual `screen_view`. Library-composition counting moves from `AnalyticsUserPropertySync` (user properties) to a pure Domain helper `AnalyticsLibrarySnapshot` (an event). Tasks are ordered so the build stays green after every task; the dead code is deleted last.

**Tech Stack:** Swift 6.3, iOS 26+, Firebase Analytics (Infrastructure only), Swift Testing.

**Spec:** `docs/superpowers/specs/2026-06-29-analytics-events-first-design.md`
**Source policy:** `~/.claude/plans/analytics-event-userproperty-twinkly-lynx.md`

## Global Constraints

- Swift 6.3, iOS 26+, bundle id `com.KeyNumber.Folino`. App name is lowercase `folino` in any user-visible string.
- Event naming: `snake_case`, ≤40 chars, `[a-z0-9_]`, start with a letter; param values ≤100 chars. GA4 *recommended* names `select_content` / `share` / `screen_view` are intentional; never use reserved `firebase_`/`google_`/`ga_` prefixes for custom names.
- **Numeric params are logged RAW** — no bucketing/rounding at collection (bucket at analysis time).
- **Zero custom user properties.** The `setUserProperty` protocol method stays (future actuation) but no key is set anywhere.
- Never log PII / user content (titles, composer, file names/paths, lyrics, raw error strings). `*_failed` events carry categorized `reason` codes only.
- Don't duplicate Firebase auto-collected events (`first_open`, `session_start`, etc.).
- Wire names/params are a stable contract once chosen (parity with the future Android catalog); don't churn them.
- No GPL dependencies. Do not add AudioKit.
- Package tests run via xcodebuild on an iOS Simulator (the SwiftLint plugin breaks `swift test`):
  `xcodebuild test -scheme <Package>-Package -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation -only-testing:<Target>/<Suite>`
  (the scheme may be `<Package>` or `<Package>-Package` depending on the xcodegen output; try `-Package` first). Test targets: `UtilityCoreTests`, `DomainTests`, `InfrastructureTests`, `ReaderTests`, `LibraryTests`, `SettingsTests`.

---

### Task 1: Log counts raw; delete collection-time bucketing (Domain)

Removes `countBucket` and switches the five count-bearing factories to raw `.int`. Call sites already pass a raw `Int`, so only the factories and their tests change.

**Files:**
- Modify: `Packages/Domain/Sources/Domain/Analytics/AnalyticsEvent+Factories.swift` (`scoreDeleted`, `scoreAddedToPlaylist`, `scoreRemovedFromPlaylist`, `tagAssigned`, `tagUnassigned`)
- Delete: `Packages/Domain/Sources/Domain/Analytics/AnalyticsBucketing.swift`
- Delete: `Packages/Domain/Tests/DomainTests/AnalyticsBucketingTests.swift`
- Test: `Packages/Domain/Tests/DomainTests/AnalyticsEventFactoryTests.swift`
- Test: `Packages/Features/Library/Tests/LibraryTests/LibraryAnalyticsTests.swift` (only if it asserts a bucketed `count` string)

**Interfaces:**
- Produces: the five factories keep their signatures (`count: Int`) but now emit `"count": .int(count)` instead of `"count": .string(countBucket(count))`.

- [ ] **Step 1: Update the factory tests to expect raw ints**

In `AnalyticsEventFactoryTests.swift`, change every count assertion from the bucketed string form to the raw int form. For example:

```swift
@Test func scoreDeletedLogsRawCount() {
    let event = AnalyticsEvent.scoreDeleted(source: .bulkEdit, mode: .bulk, count: 7)
    #expect(event.name == "score_deleted")
    #expect(event.parameters["count"] == .int(7))
    #expect(event.parameters["source"] == .string("bulk_edit"))
    #expect(event.parameters["mode"] == .string("bulk"))
}
```

Apply the same `.int(...)` expectation to the `scoreAddedToPlaylist`, `scoreRemovedFromPlaylist`, `tagAssigned`, and `tagUnassigned` tests. Remove any test that referenced `countBucket` directly.

- [ ] **Step 2: Run the Domain tests, verify the count tests fail**

Run: `xcodebuild test -scheme Domain-Package -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation -only-testing:DomainTests/AnalyticsEventFactoryTests`
Expected: FAIL — the factories still emit bucketed `.string` values.

- [ ] **Step 3: Switch the five factories to raw `.int`**

In `AnalyticsEvent+Factories.swift`, replace the bodies:

```swift
public static func scoreDeleted(source: AnalyticsSource, mode: AnalyticsActionMode, count: Int) -> AnalyticsEvent {
    AnalyticsEvent(name: "score_deleted", parameters: [
        "source": .string(source.rawValue), "mode": .string(mode.rawValue), "count": .int(count),
    ])
}

public static func scoreAddedToPlaylist(source: AnalyticsSource, count: Int) -> AnalyticsEvent {
    AnalyticsEvent(
        name: "score_added_to_playlist",
        parameters: ["source": .string(source.rawValue), "count": .int(count)],
    )
}

public static func scoreRemovedFromPlaylist(source: AnalyticsSource, count: Int) -> AnalyticsEvent {
    AnalyticsEvent(
        name: "score_removed_from_playlist",
        parameters: ["source": .string(source.rawValue), "count": .int(count)],
    )
}

public static func tagAssigned(source: AnalyticsSource, count: Int) -> AnalyticsEvent {
    AnalyticsEvent(
        name: "tag_assigned",
        parameters: ["source": .string(source.rawValue), "count": .int(count)],
    )
}

public static func tagUnassigned(source: AnalyticsSource, count: Int) -> AnalyticsEvent {
    AnalyticsEvent(
        name: "tag_unassigned",
        parameters: ["source": .string(source.rawValue), "count": .int(count)],
    )
}
```

Also update the doc comment above `scoreDeleted` (lines 41-42) — it currently states the privacy contract forbids raw counts. Replace it with:

```swift
    /// `count` is logged raw (events-first: bucket at analysis time, not at collection — see the analytics spec).
```

- [ ] **Step 4: Delete the bucketing helper and its test**

```bash
git rm Packages/Domain/Sources/Domain/Analytics/AnalyticsBucketing.swift
git rm Packages/Domain/Tests/DomainTests/AnalyticsBucketingTests.swift
```

- [ ] **Step 5: Fix any other caller of `countBucket`**

Run: `grep -rn "countBucket" Packages/ App/`
Expected after the edits above: the only remaining hit is `AnalyticsUserPropertySync.swift` (deleted in Task 7). If `LibraryAnalyticsTests.swift` asserts a bucketed count string, change those assertions to `.int(...)` too. Do **not** touch `AnalyticsUserPropertySync.swift` in this task.

- [ ] **Step 6: Run Domain + Library tests, verify pass**

Run: `xcodebuild test -scheme Domain-Package -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation -only-testing:DomainTests/AnalyticsEventFactoryTests`
Run: `xcodebuild test -scheme Library-Package -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation -only-testing:LibraryTests/LibraryAnalyticsTests`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add Packages/Domain Packages/Features/Library
git commit -m "feat(analytics): log counts raw, drop collection-time bucketing"
```

---

### Task 2: Add new event factories + screen enum + logScreen convenience (Domain)

Purely additive. Adds the `screen_view`, `settings_snapshot`, `library_snapshot`, and `annotation_ended` factories, the `AnalyticsScreen` enum, and an `Analytics.logScreen(_:)` convenience.

**Files:**
- Create: `Packages/Domain/Sources/Domain/Analytics/AnalyticsScreen.swift`
- Create: `Packages/Domain/Sources/Domain/Analytics/Analytics+LogScreen.swift`
- Modify: `Packages/Domain/Sources/Domain/Analytics/AnalyticsEvent+Factories.swift` (append the new factories)
- Test: `Packages/Domain/Tests/DomainTests/AnalyticsEventFactoryTests.swift`

**Interfaces:**
- Produces:
  - `enum AnalyticsScreen: String { library, reader, scoreInfo, settings, recentlyDeleted, playlistDetail, tagDetail }` with snake_case raw values.
  - `AnalyticsEvent.screen(_ screen: AnalyticsScreen) -> AnalyticsEvent` → `"screen_view"`, `["firebase_screen": .string(screen.rawValue)]`.
  - `AnalyticsEvent.settingsSnapshot(metronome:pictureInPicture:collapseMultiMeasureRests:showInvisibles:keepScreenAwake:showSeekBar:repeatMode:playlistContinuation:a4ReferenceHz:layoutMode:crashReportingEnabled:soundfontPreset:) -> AnalyticsEvent` → `"settings_snapshot"`.
  - `AnalyticsEvent.librarySnapshot(total:mscz2:mscz3:mscz4:musicXML:midi:pdf:playlistCount:tagCount:favoriteCount:) -> AnalyticsEvent` → `"library_snapshot"`.
  - `AnalyticsEvent.annotationEnded(strokes: Int, durationSec: Double) -> AnalyticsEvent` → `"annotation_ended"`, `["ink_strokes": .int(strokes), "duration_sec": .double(durationSec)]`.
  - `Analytics.logScreen(_ screen: AnalyticsScreen)` default method calling `log(.screen(screen))`.

- [ ] **Step 1: Write the failing tests for the new factories**

Append to `AnalyticsEventFactoryTests.swift`:

```swift
@Test func screenFactory() {
    let event = AnalyticsEvent.screen(.reader)
    #expect(event.name == "screen_view")
    #expect(event.parameters["firebase_screen"] == .string("reader"))
}

@Test func annotationEndedFactory() {
    let event = AnalyticsEvent.annotationEnded(strokes: 12, durationSec: 34.5)
    #expect(event.name == "annotation_ended")
    #expect(event.parameters["ink_strokes"] == .int(12))
    #expect(event.parameters["duration_sec"] == .double(34.5))
}

@Test func librarySnapshotFactory() {
    let event = AnalyticsEvent.librarySnapshot(
        total: 30, mscz2: 1, mscz3: 2, mscz4: 3, musicXML: 4, midi: 5, pdf: 6,
        playlistCount: 7, tagCount: 8, favoriteCount: 9,
    )
    #expect(event.name == "library_snapshot")
    #expect(event.parameters["score_count_total"] == .int(30))
    #expect(event.parameters["score_count_mscz4"] == .int(3))
    #expect(event.parameters["score_count_pdf"] == .int(6))
    #expect(event.parameters["playlist_count"] == .int(7))
    #expect(event.parameters["favorite_count"] == .int(9))
}

@Test func settingsSnapshotFactory() {
    let event = AnalyticsEvent.settingsSnapshot(
        metronome: true, pictureInPicture: false, collapseMultiMeasureRests: true,
        showInvisibles: false, keepScreenAwake: true, showSeekBar: true,
        repeatMode: .abLoop, playlistContinuation: .playThrough, a4ReferenceHz: 442,
        layoutMode: .page, crashReportingEnabled: true, soundfontPreset: "lightweight",
    )
    #expect(event.name == "settings_snapshot")
    #expect(event.parameters["metronome_enabled"] == .bool(true))
    #expect(event.parameters["repeat_mode"] == .string("ab_loop"))
    #expect(event.parameters["playlist_continuation"] == .string("play_through"))
    #expect(event.parameters["a4_reference_hz"] == .double(442))
    #expect(event.parameters["layout_mode"] == .string("page"))
    #expect(event.parameters["soundfont_preset"] == .string("lightweight"))
}
```

- [ ] **Step 2: Run, verify fail**

Run: `xcodebuild test -scheme Domain-Package -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation -only-testing:DomainTests/AnalyticsEventFactoryTests`
Expected: FAIL — factories / `AnalyticsScreen` not defined.

- [ ] **Step 3: Create the `AnalyticsScreen` enum**

Create `Packages/Domain/Sources/Domain/Analytics/AnalyticsScreen.swift`:

```swift
/// A logical screen identity for the manual `screen_view` event. SwiftUI is a single `UIHostingController`, so
/// Firebase does not auto-collect screen views — each top-level screen emits one explicitly on appear. Raw values are
/// the wire `firebase_screen` parameter; keep them stable.
public enum AnalyticsScreen: String, Sendable {
    case library
    case reader
    case scoreInfo = "score_info"
    case settings
    case recentlyDeleted = "recently_deleted"
    case playlistDetail = "playlist_detail"
    case tagDetail = "tag_detail"
}
```

- [ ] **Step 4: Append the new factories**

Append to `AnalyticsEvent+Factories.swift` (inside the existing `extension AnalyticsEvent`, after the Settings / app section):

```swift
    // MARK: Screen views

    /// Manual `screen_view` (reserved GA4 recommended event). `firebase_screen` is the only param; Firebase fills the
    /// rest. Emitted from each top-level screen's `onAppear` because SwiftUI screen views are not auto-collected.
    public static func screen(_ screen: AnalyticsScreen) -> AnalyticsEvent {
        AnalyticsEvent(name: "screen_view", parameters: ["firebase_screen": .string(screen.rawValue)])
    }

    // MARK: Launch snapshots (events-first replacements for user properties)

    /// One-per-launch snapshot of durable settings. Raw values — bucket at analysis time. "Current settings per user"
    /// is the latest `settings_snapshot`; `setting_changed` adds the change history.
    public static func settingsSnapshot(
        metronome: Bool,
        pictureInPicture: Bool,
        collapseMultiMeasureRests: Bool,
        showInvisibles: Bool,
        keepScreenAwake: Bool,
        showSeekBar: Bool,
        repeatMode: RepeatMode,
        playlistContinuation: PlaylistContinuationMode,
        a4ReferenceHz: Double,
        layoutMode: ReaderLayoutMode,
        crashReportingEnabled: Bool,
        soundfontPreset: String,
    ) -> AnalyticsEvent {
        AnalyticsEvent(name: "settings_snapshot", parameters: [
            "metronome_enabled": .bool(metronome),
            "picture_in_picture_enabled": .bool(pictureInPicture),
            "collapse_multi_measure_rests": .bool(collapseMultiMeasureRests),
            "show_invisible_elements": .bool(showInvisibles),
            "keep_screen_awake": .bool(keepScreenAwake),
            "show_seek_bar": .bool(showSeekBar),
            "repeat_mode": .string(repeatMode.analyticsValue),
            "playlist_continuation": .string(playlistContinuation.analyticsValue),
            "a4_reference_hz": .double(a4ReferenceHz),
            "layout_mode": .string(layoutMode.analyticsValue),
            "crash_reporting_enabled": .bool(crashReportingEnabled),
            "soundfont_preset": .string(soundfontPreset),
        ])
    }

    /// One-per-launch snapshot of library composition. Raw counts (metrics) — bucket at analysis time. Replaces the
    /// former library-count user properties.
    public static func librarySnapshot(
        total: Int, mscz2: Int, mscz3: Int, mscz4: Int,
        musicXML: Int, midi: Int, pdf: Int,
        playlistCount: Int, tagCount: Int, favoriteCount: Int,
    ) -> AnalyticsEvent {
        AnalyticsEvent(name: "library_snapshot", parameters: [
            "score_count_total": .int(total),
            "score_count_mscz2": .int(mscz2),
            "score_count_mscz3": .int(mscz3),
            "score_count_mscz4": .int(mscz4),
            "score_count_musicxml": .int(musicXML),
            "score_count_midi": .int(midi),
            "score_count_pdf": .int(pdf),
            "playlist_count": .int(playlistCount),
            "tag_count": .int(tagCount),
            "favorite_count": .int(favoriteCount),
        ])
    }

    /// Session-level annotation summary, emitted when annotation mode exits. Replaces the per-stroke
    /// `annotation_ink_committed` so the pipeline is not flooded with one event per stroke.
    public static func annotationEnded(strokes: Int, durationSec: Double) -> AnalyticsEvent {
        AnalyticsEvent(
            name: "annotation_ended",
            parameters: ["ink_strokes": .int(strokes), "duration_sec": .double(durationSec)],
        )
    }
```

- [ ] **Step 5: Add the `logScreen` convenience**

Create `Packages/Domain/Sources/Domain/Analytics/Analytics+LogScreen.swift`:

```swift
import UtilityCore

extension Analytics {
    /// Convenience for the manual `screen_view` event. Call from a top-level screen's `onAppear`.
    public func logScreen(_ screen: AnalyticsScreen) {
        log(.screen(screen))
    }
}
```

- [ ] **Step 6: Run the tests, verify pass**

Run: `xcodebuild test -scheme Domain-Package -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation -only-testing:DomainTests/AnalyticsEventFactoryTests`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add Packages/Domain
git commit -m "feat(analytics): add screen_view, settings_snapshot, library_snapshot, annotation_ended factories"
```

---

### Task 3: Add `AnalyticsLibrarySnapshot` pure helper (Domain)

Moves the library-composition counting out of the user-property sync into a pure function that returns the `library_snapshot` event. Additive — `AnalyticsUserPropertySync` is untouched here (deleted in Task 7).

**Files:**
- Create: `Packages/Domain/Sources/Domain/Analytics/AnalyticsLibrarySnapshot.swift`
- Test: `Packages/Domain/Tests/DomainTests/AnalyticsLibrarySnapshotTests.swift`

**Interfaces:**
- Consumes: `AnalyticsEvent.librarySnapshot(...)` (Task 2), `ScoreItem`, `ScoreFormat.detect(filename:)`, `ScoreItem.localFileName`, `ScoreItem.museScoreMajorVersion`, `ScoreItem.isFavorite` (verify the favorite flag's exact property name on `ScoreItem` while implementing; adjust the `favoriteCount` predicate to match).
- Produces: `AnalyticsLibrarySnapshot.event(items: [ScoreItem], playlistCount: Int, tagCount: Int) -> AnalyticsEvent`.

- [ ] **Step 1: Write the failing test**

Create `AnalyticsLibrarySnapshotTests.swift` (mirror the construction style of the existing `AnalyticsUserPropertySyncTests.swift` for building `ScoreItem` fixtures):

```swift
import Testing
@testable import Domain

@Suite struct AnalyticsLibrarySnapshotTests {
    @Test func countsByFormatRaw() {
        let items = [
            makeItem("a.mscz", museScoreMajorVersion: 4),
            makeItem("b.mscz", museScoreMajorVersion: 3),
            makeItem("c.musicxml"),
            makeItem("d.mid"),
            makeItem("e.pdf"),
        ]
        let event = AnalyticsLibrarySnapshot.event(items: items, playlistCount: 2, tagCount: 1)
        #expect(event.name == "library_snapshot")
        #expect(event.parameters["score_count_total"] == .int(5))
        #expect(event.parameters["score_count_mscz4"] == .int(1))
        #expect(event.parameters["score_count_mscz3"] == .int(1))
        #expect(event.parameters["score_count_musicxml"] == .int(1))
        #expect(event.parameters["score_count_midi"] == .int(1))
        #expect(event.parameters["score_count_pdf"] == .int(1))
        #expect(event.parameters["playlist_count"] == .int(2))
        #expect(event.parameters["tag_count"] == .int(1))
    }

    // Build a ScoreItem the same way AnalyticsUserPropertySyncTests does (copy its helper). Replace the body to
    // match ScoreItem's real initializer.
    private func makeItem(_ name: String, museScoreMajorVersion: Int? = nil) -> ScoreItem { /* see existing helper */ }
}
```

When implementing, copy the exact `ScoreItem` fixture helper from `AnalyticsUserPropertySyncTests.swift` so this compiles against the real initializer.

- [ ] **Step 2: Run, verify fail**

Run: `xcodebuild test -scheme Domain-Package -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation -only-testing:DomainTests/AnalyticsLibrarySnapshotTests`
Expected: FAIL — `AnalyticsLibrarySnapshot` not defined.

- [ ] **Step 3: Implement the helper**

Create `AnalyticsLibrarySnapshot.swift` (port the counting logic from `AnalyticsUserPropertySync`, emitting raw ints in one event):

```swift
import UtilityCore

/// Pure mapping from library state to the `library_snapshot` event. Format is derived from `localFileName` via
/// `ScoreFormat.detect(filename:)` (ScoreItem does not store format). `museScoreMajorVersion` is `nil` for non-MuseScore
/// rows and pre-field rows; treated as v4 (current default) for mscz rows. Counts are raw — bucket at analysis time.
/// Lifted to Domain so iOS and a future Android path share one implementation.
public enum AnalyticsLibrarySnapshot {
    public static func event(items: [ScoreItem], playlistCount: Int, tagCount: Int) -> AnalyticsEvent {
        func format(of item: ScoreItem) -> ScoreFormat? { ScoreFormat.detect(filename: item.localFileName) }
        func msczMajor(_ item: ScoreItem) -> Int? {
            guard format(of: item) == .mscz else { return nil }
            return item.museScoreMajorVersion ?? 4
        }
        func count(_ predicate: (ScoreItem) -> Bool) -> Int { items.filter(predicate).count }

        return .librarySnapshot(
            total: items.count,
            mscz2: count { msczMajor($0) == 2 },
            mscz3: count { msczMajor($0) == 3 },
            mscz4: count { msczMajor($0) == 4 },
            musicXML: count { format(of: $0) == .musicXML || format(of: $0) == .mxl },
            midi: count { format(of: $0) == .midi },
            pdf: count { format(of: $0) == .pdf },
            playlistCount: playlistCount,
            tagCount: tagCount,
            favoriteCount: count { $0.isFavorite },
        )
    }
}
```

If `ScoreItem`'s favorite flag is named differently than `isFavorite`, fix the predicate to the real property (grep `ScoreItem` for the favorite field).

- [ ] **Step 4: Run, verify pass**

Run: `xcodebuild test -scheme Domain-Package -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation -only-testing:DomainTests/AnalyticsLibrarySnapshotTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Packages/Domain
git commit -m "feat(analytics): add AnalyticsLibrarySnapshot pure event helper"
```

---

### Task 4: Emit `library_snapshot` + `settings_snapshot` at launch; drop user-property push (App)

Rewrites `AppBootstrap.pushAnalyticsSnapshot` to emit the two launch events instead of setting user properties. After this task `AnalyticsUserPropertySync` and all `AnalyticsUserProperty` keys are unused (deleted in Task 7).

**Files:**
- Modify: `App/AppBootstrap.swift` (`pushAnalyticsSnapshot`, lines ~133-162)

**Interfaces:**
- Consumes: `AnalyticsEvent.settingsSnapshot(...)`, `AnalyticsLibrarySnapshot.event(...)` (Tasks 2-3); the storage keys `ReaderGlobalSettingsKey.*`, `PrivacySettingsKey.*`; `repository.scoreItems`, `repository.playlists`, and the tags collection (use the repository's tags accessor — grep `LiveScoreLibraryRepository` for the tag list property; if none, pass `tagCount: 0` and note it).

- [ ] **Step 1: Replace `pushAnalyticsSnapshot`**

In `App/AppBootstrap.swift`, replace the whole `pushAnalyticsSnapshot(repository:)` method (currently lines ~133-162) with:

```swift
    /// Emits the two launch snapshot events (events-first; no user properties). Called once after the repository is
    /// ready so library counts are current. Behind the consent gate inside the sink. Sort order is not persisted
    /// (held in-memory in `ScoreListViewModel`), so it is intentionally not part of the settings snapshot — sort is
    /// captured by the `sort_changed` event instead.
    private func pushAnalyticsSnapshot(repository: LiveScoreLibraryRepository) {
        guard let analytics else { return }
        let defaults = UserDefaults.standard

        analytics.log(AnalyticsLibrarySnapshot.event(
            items: repository.scoreItems,
            playlistCount: repository.playlists.count,
            tagCount: repository.tags.count,
        ))

        func boolSetting(_ key: String, default defaultValue: Bool) -> Bool {
            defaults.object(forKey: key) as? Bool ?? defaultValue
        }
        let repeatMode = RepeatMode(rawValue: defaults.string(forKey: ReaderGlobalSettingsKey.repeatMode) ?? "")
            ?? .off
        let continuation = PlaylistContinuationMode(
            rawValue: defaults.string(forKey: ReaderGlobalSettingsKey.playlistContinuationMode) ?? "",
        ) ?? .playThrough
        let layoutMode = ReaderLayoutMode(rawValue: defaults.string(forKey: ReaderGlobalSettingsKey.layoutMode) ?? "")
            ?? .page
        let a4 = defaults.object(forKey: ReaderGlobalSettingsKey.a4ReferenceHz) as? Double ?? 440

        analytics.log(.settingsSnapshot(
            metronome: boolSetting(ReaderGlobalSettingsKey.metronomeEnabled, default: false),
            pictureInPicture: boolSetting(ReaderGlobalSettingsKey.pictureInPictureEnabled, default: false),
            collapseMultiMeasureRests: boolSetting(ReaderGlobalSettingsKey.collapseMultiMeasureRests, default: false),
            showInvisibles: boolSetting(ReaderGlobalSettingsKey.showInvisibleElements, default: false),
            keepScreenAwake: boolSetting(ReaderGlobalSettingsKey.keepScreenAwakeEnabled, default: true),
            showSeekBar: boolSetting(ReaderGlobalSettingsKey.showSeekBarEnabled, default: true),
            repeatMode: repeatMode,
            playlistContinuation: continuation,
            a4ReferenceHz: a4,
            layoutMode: layoutMode,
            crashReportingEnabled: boolSetting(PrivacySettingsKey.crashReportingEnabled, default: true),
            soundfontPreset: museScoreGeneralProvider?.currentPreset.rawValue
                ?? SoundfontPreset.lightweight.rawValue,
        ))
    }
```

If `repository.tags` is not the correct accessor, grep `LiveScoreLibraryRepository` for its tag collection and use that; if tags aren't synchronously available here, pass `tagCount: 0` and add a `// TODO(analytics): wire tag count when available` — but prefer the real accessor.

Also delete the now-inaccurate doc comment block above the method (the old one referencing `AnalyticsUserPropertySync`).

- [ ] **Step 2: Build the app target, verify it compiles**

Run: `xcodebuild -project Folino.xcodeproj -scheme Folino -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation build`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add App/AppBootstrap.swift
git commit -m "feat(analytics): emit library_snapshot + settings_snapshot at launch (drop user-property push)"
```

---

### Task 5: Session-aggregate annotation; drop the annotation user property (Reader)

Replaces per-stroke `annotation_ink_committed` + the `has_used_annotation` user property with a single `annotation_ended` event carrying the session stroke count and duration.

**Files:**
- Modify: `Packages/Features/Reader/Sources/Reader/ReaderViewModel.swift` (add session-tracking state)
- Modify: `Packages/Features/Reader/Sources/Reader/ReaderViewModel+Analytics.swift` (`toggleAnnotation`, `logAnnotationInkCommitted` → stroke counter; add `endAnnotationSessionIfNeeded`)
- Modify: `Packages/Features/Reader/Sources/Reader/Screens/ReaderRootScreen.swift` (flush on disappear)
- Test: `Packages/Features/Reader/Tests/ReaderTests/AnnotationAnalyticsTests.swift`

**Interfaces:**
- Consumes: `AnalyticsEvent.annotationEnded(strokes:durationSec:)` (Task 2).
- Produces: `ReaderViewModel.recordAnnotationStroke()` (replaces `logAnnotationInkCommitted`), `ReaderViewModel.endAnnotationSessionIfNeeded()`. The per-stroke caller of `logAnnotationInkCommitted` (in `annotationDrawingsDidChange`) must call `recordAnnotationStroke()` instead — grep for the call site.

- [ ] **Step 1: Update the annotation tests for session aggregation**

Rewrite `AnnotationAnalyticsTests.swift` so it asserts: entering annotation logs `annotation_started`; N stroke records + exit logs one `annotation_ended` with `ink_strokes == N`; no `annotation_ink_committed` and no `setUserProperty` occur. Use the existing `SpyAnalytics` (it already records logged events; confirm it also records `setUserProperty` calls, else extend it). Example:

```swift
@Test @MainActor func annotationSessionEmitsEndedWithStrokeCount() {
    let spy = SpyAnalytics()
    let vm = makeReaderViewModel(analytics: spy)   // reuse existing test factory
    vm.toggleAnnotation()                          // enter
    vm.recordAnnotationStroke()
    vm.recordAnnotationStroke()
    vm.recordAnnotationStroke()
    vm.toggleAnnotation()                          // exit → flush
    #expect(spy.events.contains { $0.name == "annotation_started" })
    let ended = spy.events.first { $0.name == "annotation_ended" }
    #expect(ended?.parameters["ink_strokes"] == .int(3))
    #expect(!spy.events.contains { $0.name == "annotation_ink_committed" })
    #expect(spy.userProperties.isEmpty)            // no user property set
}
```

If `SpyAnalytics` doesn't expose `userProperties`, add a `setUserProperty` recorder to it (in `Packages/Features/Reader/Tests/ReaderTests/Fakes/SpyAnalytics.swift`).

- [ ] **Step 2: Run, verify fail**

Run: `xcodebuild test -scheme Reader-Package -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation -only-testing:ReaderTests/AnnotationAnalyticsTests`
Expected: FAIL — `recordAnnotationStroke` not defined; per-stroke event still emitted.

- [ ] **Step 3: Add session state to `ReaderViewModel`**

In `ReaderViewModel.swift`, near the `isAnnotating` declaration (line ~83), add:

```swift
    /// Strokes committed since the current annotation session began. Flushed into `annotation_ended` on exit.
    private var annotationStrokeCount = 0
    /// Wall-clock start of the current annotation session, for `annotation_ended`'s `duration_sec`.
    private var annotationSessionStart: Date?
```

- [ ] **Step 4: Rewrite the annotation analytics methods**

In `ReaderViewModel+Analytics.swift`, replace `toggleAnnotation` and `logAnnotationInkCommitted` with:

```swift
    /// Toggle annotation (Apple Pencil) mode. Entering logs `annotation_started` and starts a stroke/duration session;
    /// exiting flushes the session as one `annotation_ended`. Entry is the mode-entry signal; the session summary is the
    /// real pencil-usage signal (events-first: aggregated, not per-stroke).
    func toggleAnnotation() {
        isAnnotating.toggle()
        if isAnnotating {
            annotationStrokeCount = 0
            annotationSessionStart = Date()
            analytics.log(.annotationStarted())
        } else {
            endAnnotationSessionIfNeeded()
        }
    }

    /// Count one committed stroke for the active session. Called from `annotationDrawingsDidChange` when a stroke is
    /// genuinely committed (net increase). Emits nothing on its own — the total ships in `annotation_ended`.
    func recordAnnotationStroke() {
        annotationStrokeCount += 1
    }

    /// Flush the current annotation session as one `annotation_ended`, if a session is active. Idempotent: a second
    /// call without a new session does nothing. Called on annotation-mode exit and on Reader teardown.
    func endAnnotationSessionIfNeeded() {
        guard let start = annotationSessionStart else { return }
        let duration = Date().timeIntervalSince(start)
        analytics.log(.annotationEnded(strokes: annotationStrokeCount, durationSec: duration))
        annotationSessionStart = nil
        annotationStrokeCount = 0
    }
```

Remove the `import` of nothing extra; `Date` needs `Foundation` (already imported). Delete the `AnalyticsStateKey` usage and the `setUserProperty(.hasUsedAnnotation)` call (both were inside the old `logAnnotationInkCommitted`).

- [ ] **Step 5: Point the stroke call site at `recordAnnotationStroke`**

Run: `grep -rn "logAnnotationInkCommitted" Packages/Features/Reader/Sources`
Replace the single caller (in the `annotationDrawingsDidChange` path) with `recordAnnotationStroke()`.

- [ ] **Step 6: Flush on Reader teardown**

In `ReaderRootScreen.swift`, add to the root view's modifiers so a session left open when the Reader closes is still recorded:

```swift
        .onDisappear { viewModel.endAnnotationSessionIfNeeded() }
```

(Place it on the same view that owns `viewModel`. If an `.onDisappear` already exists there, add the call to its body.)

- [ ] **Step 7: Run the Reader analytics tests, verify pass**

Run: `xcodebuild test -scheme Reader-Package -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation -only-testing:ReaderTests/AnnotationAnalyticsTests -only-testing:ReaderTests/ReaderAnalyticsTests`
Expected: PASS. If `ReaderAnalyticsTests` referenced `annotation_ink_committed` or the annotation user property, update those expectations too.

- [ ] **Step 8: Commit**

```bash
git add Packages/Features/Reader
git commit -m "feat(analytics): session-aggregate annotation into annotation_ended; drop has_used_annotation property"
```

---

### Task 6: Manual `screen_view` on top-level screens (Reader / Library / Settings)

Adds one `logScreen(_:)` call per top-level screen `onAppear`.

**Files:**
- Modify: `Packages/Features/Library/Sources/Library/Screens/LibraryRootScreen.swift` (`.library`)
- Modify: `Packages/Features/Library/Sources/Library/Screens/RecentlyDeletedScreen.swift` (`.recentlyDeleted`)
- Modify: `Packages/Features/Library/Sources/Library/Screens/PlaylistDetailScreen.swift` (`.playlistDetail`)
- Modify: `Packages/Features/Library/Sources/Library/Screens/TagDetailScreen.swift` (`.tagDetail`)
- Modify: `Packages/Features/Reader/Sources/Reader/Screens/ReaderRootScreen.swift` (`.reader`)
- Modify: the Settings sheet root view (`.settings`) and the score-info sheet view (`.scoreInfo`) — locate each (grep `SettingsSheet` / the score-info view); wire the same pattern.

**Interfaces:**
- Consumes: `Analytics.logScreen(_:)` (Task 2). Each screen needs an `any Analytics` handle — most already hold one via their view model (`viewModel.analytics`) or an injected `analytics` property. Use whichever the screen already has; do not add new injection plumbing beyond passing `analytics` to a screen that lacks it.

- [ ] **Step 1: Wire `LibraryRootScreen`**

Add to the root view's body modifiers (use the screen's existing analytics handle — confirm whether it is `viewModel.analytics` or an injected `analytics`):

```swift
        .onAppear { analytics.logScreen(.library) }
```

- [ ] **Step 2: Wire the remaining Library screens**

Same pattern, with the matching `AnalyticsScreen` case, on each screen's root `onAppear`:
- `RecentlyDeletedScreen` → `.onAppear { analytics.logScreen(.recentlyDeleted) }`
- `PlaylistDetailScreen` → `.onAppear { analytics.logScreen(.playlistDetail) }`
- `TagDetailScreen` → `.onAppear { analytics.logScreen(.tagDetail) }`

For any screen that does not already hold an `Analytics`, thread it from the parent that constructs the screen (the parent has `LibraryViewModel.analytics`). Keep the change minimal — one constructor param + pass-through.

- [ ] **Step 3: Wire `ReaderRootScreen`**

```swift
        .onAppear { viewModel.analytics.logScreen(.reader) }
```

- [ ] **Step 4: Wire Settings + score-info**

Locate the Settings sheet root view (grep `SettingsSheet`) and the score-info sheet view (grep `scoreInfo` / `ScoreInfo`). Add, using each view's existing `analytics` handle:
- Settings root → `.onAppear { analytics.logScreen(.settings) }`
- Score-info view → `.onAppear { analytics.logScreen(.scoreInfo) }`

(The existing `settings_opened` smoke event stays; `screen_view` is additive and complementary.)

- [ ] **Step 5: Build all touched packages + app, verify compile**

Run: `xcodebuild -project Folino.xcodeproj -scheme Folino -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation build`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 6: Commit**

```bash
git add Packages/Features App
git commit -m "feat(analytics): emit manual screen_view on top-level screens"
```

---

### Task 7: Delete dead user-property + per-stroke code (Domain / Utility)

Everything below is now unused (verified by grep). Delete it and run the full analytics test pass.

**Files:**
- Delete: `Packages/Domain/Sources/Domain/Analytics/AnalyticsUserPropertySync.swift`
- Delete: `Packages/Domain/Tests/DomainTests/AnalyticsUserPropertySyncTests.swift`
- Delete: `Packages/Utility/Sources/UtilityCore/AnalyticsUserProperty+Keys.swift`
- Delete: `Packages/Utility/Tests/UtilityCoreTests/AnalyticsUserPropertyKeyTests.swift`
- Modify: `Packages/Domain/Sources/Domain/Analytics/AnalyticsEvent+Factories.swift` (remove `annotationInkCommitted`)
- Modify: `Packages/Domain/Tests/DomainTests/AnalyticsEventFactoryTests.swift` (remove the `annotationInkCommitted` test)
- Modify/Delete: `Packages/Domain/Sources/Domain/Models/AnalyticsStateKey.swift` (remove `hasUsedAnnotation`; delete the file if it becomes empty)

- [ ] **Step 1: Confirm everything is unused**

Run: `grep -rn "AnalyticsUserPropertySync\|AnalyticsUserProperty\.\|annotationInkCommitted\|hasUsedAnnotation\|annotation_ink_committed" Packages/ App/ | grep -v Tests | grep -v ".build"`
Expected: no production hits (only the definitions about to be deleted). If a hit remains, fix that caller first (it should have been handled in Tasks 4-5).

- [ ] **Step 2: Delete the dead files**

```bash
git rm Packages/Domain/Sources/Domain/Analytics/AnalyticsUserPropertySync.swift
git rm Packages/Domain/Tests/DomainTests/AnalyticsUserPropertySyncTests.swift
git rm Packages/Utility/Sources/UtilityCore/AnalyticsUserProperty+Keys.swift
git rm Packages/Utility/Tests/UtilityCoreTests/AnalyticsUserPropertyKeyTests.swift
```

- [ ] **Step 3: Remove `annotationInkCommitted` factory + its test**

Delete the `annotationInkCommitted()` factory (lines ~159-161) from `AnalyticsEvent+Factories.swift` and its test from `AnalyticsEventFactoryTests.swift`.

- [ ] **Step 4: Remove the `hasUsedAnnotation` state key**

In `AnalyticsStateKey.swift`, remove the `hasUsedAnnotation` constant. If that leaves the enum empty, `git rm` the file and remove any now-dangling `import`/reference.

- [ ] **Step 5: Run the full analytics test pass across packages**

Run each, expect PASS:
```
xcodebuild test -scheme Utility-Package -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation -only-testing:UtilityCoreTests
xcodebuild test -scheme Domain-Package -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation -only-testing:DomainTests
xcodebuild test -scheme Infrastructure-Package -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation -only-testing:InfrastructureTests/FirebaseAnalyticsClientGatingTests
xcodebuild test -scheme Reader-Package -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation -only-testing:ReaderTests/ReaderAnalyticsTests -only-testing:ReaderTests/AnnotationAnalyticsTests
xcodebuild test -scheme Library-Package -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation -only-testing:LibraryTests/LibraryAnalyticsTests
xcodebuild test -scheme Settings-Package -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation -only-testing:SettingsTests/SettingChangedAnalyticsTests
```

- [ ] **Step 6: Full app build**

Run: `xcodebuild -project Folino.xcodeproj -scheme Folino -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation build`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 7: Commit**

```bash
git add Packages App
git commit -m "refactor(analytics): delete user-property sync, keys, per-stroke ink event"
```

---

## Manual / runtime verification (after the tasks)

1. **DebugView**: run on device/sim with `-FIRAnalyticsDebugEnabled`. Exercise: cold launch (expect `library_snapshot` + `settings_snapshot` with **raw** counts/values, no buckets), open each screen (expect `screen_view` with `firebase_screen`), delete N scores (expect `score_deleted` `count` = raw N), annotate then exit (expect one `annotation_ended` with `ink_strokes`), change a setting (expect `setting_changed`).
2. Confirm **no** `user property` is set (DebugView "User properties" stays empty) and **no** `annotation_ink_committed` appears.
3. **Consent gate**: toggle analytics off in Settings → confirm nothing forwards.
4. **Prerequisite (user-owned):** enable Firebase **BigQuery export** in the Folino Firebase project — not retroactive, so do it before/at release.

## Self-Review notes (coverage)

- Spec §"user properties → zero": Tasks 4 (stop push), 5 (annotation prop), 7 (delete keys/sync). ✓
- Spec §"bucketing removed": Task 1. ✓
- Spec §"new events screen_view/settings_snapshot/library_snapshot": Tasks 2, 3, 4, 6. ✓
- Spec §"annotation session-aggregated": Task 5. ✓
- Spec §"keep plumbing / typed factories / gate / Firebase isolation": no task removes them (FirebaseAnalyticsClient untouched). ✓
- Spec §"`*_failed` reason codes": already satisfied by the existing `score_import_failed` factory; no change needed.
- Open confirmations folded into steps (not placeholders): `ScoreItem` favorite property name (T3), repository tags accessor (T4), each screen's analytics handle + Settings/score-info view locations (T6), `SpyAnalytics.userProperties` recorder (T5).
