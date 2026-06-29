# Analytics — Events-First Taxonomy Migration (Folino)

**Date:** 2026-06-29
**Status:** Approved (design), pending spec review
**Source policy:** `~/.claude/plans/analytics-event-userproperty-twinkly-lynx.md`
(VocalTuner taxonomy doc — its **Guiding Policy** is app-agnostic and is adopted here verbatim).

## Context

Folino already ships a full, type-safe Firebase Analytics integration (merged to local
`main`, **unpushed, not yet released**): an `Analytics` protocol injected by constructor, the
`AnalyticsEvent` / `AnalyticsValue` / `AnalyticsUserProperty` value types, 31 typed event
factories, an `AnalyticsSource` attribution enum, collection-time count **bucketing**, ~11
**user properties** with a launch-time sync, a Firebase-isolated adapter with a consent gate,
and ~57 call sites across Library / Reader / ImportExport / Settings.

That implementation predates the **events-first** policy. Because Folino's analytics is not
released, the wire contract can change freely. This spec re-aligns the **taxonomy** (what we
measure and how) to the events-first policy while keeping the existing **plumbing** (protocol,
value types, typed-factory pattern, consent gate, Firebase isolation).

The analysis workflow is **programmatic** — raw export (BigQuery) / GA4 API consumed by an
agent, not the GA4 console UI. That single fact drives the whole design (see Guiding Policy).

## Guiding Policy (adopted from the source doc — the transferable core)

1. **Default everything to events; user properties are a last resort.** An event is a
   timestamped, append-only entry, so the stream carries both history and current state; a
   user's "current value" is the latest event that carried it, derivable at analysis time.
2. **Analysis is programmatic → events-first.** *Prerequisite:* enable Firebase **BigQuery
   export** now — free, daily, **not retroactive**. (Owner: user, via Firebase console.)
3. **User properties are an *actuation* tool, not analysis** (Remote Config / experiments /
   FCM / Ads), and only when low-latency targeting matters. Decision rule: *"act on this
   segment inside Google's tools, with low latency?"* → user property, else event. No lock-in:
   properties populate forward from the day added.
4. **Log numeric params raw — never bucket/round at collection.** Re-aggregate at analysis
   time. The `(other)` cardinality problem only bites a value used as a GA4 **dimension**; raw
   params in the BQ export or used as metrics are fine. Don't register a high-cardinality param
   as a custom dimension — leave it BQ-only.
5. **Never log PII or user content** — score titles, file names/paths, lyrics, raw
   `NSError.localizedDescription`. Use categorized `reason` codes and provenance enums.
6. **Don't duplicate Firebase auto-collected events.**
7. **Naming:** `snake_case`, ≤40 chars, `[a-z0-9_]`, start with a letter; param value ≤100
   chars. GA4 *recommended* names (`select_content`, `share`, `screen_view`) are encouraged;
   reserved `firebase_`/`google_`/`ga_` prefixes are forbidden.

## What stays (plumbing — unchanged)

- `Analytics` protocol (`log` / `setUserProperty` / `setCollectionEnabled`), `NoopAnalytics`,
  constructor injection (`any Analytics`) into every feature view model.
- Value types `AnalyticsEvent { name, [String: AnalyticsValue] }`, `AnalyticsValue`
  (`string/int/double/bool`), `AnalyticsUserProperty { name }`.
- The **typed-factory** pattern (`AnalyticsEvent.scoreImported(...)`) — endorsed by the policy
  ("names can't drift"). Factories are adjusted, not removed.
- `AnalyticsSource` (low-cardinality enum) and the domain-enum `analyticsValue` mappings —
  these are event-param helpers, fully compatible with events-first.
- The consent gate (`FirebaseAnalyticsClient`: local `NSLock` flag + SDK
  `setAnalyticsCollectionEnabled`) and the Firebase-import isolation in Infrastructure.
- `setUserProperty` stays on the protocol for future actuation use — but **no keys are set**
  (see User Properties).

## What changes (taxonomy delta)

### 1. User properties → **zero** (Policy #1, #3)

All current user properties are analysis-only and become events. The launch user-property push
is replaced by two launch **events** (below).

| Removed user property | Replacement |
|---|---|
| `librarySizeBucket`, `scoreCountMscz2/3/4`, `scoreCountMusicXML/Midi/Pdf` | `library_snapshot` event (raw counts) |
| `layoutMode`, `soundfontPreset`, `currentSortOrder`, `crashReportingEnabled` | `settings_snapshot` event |
| `hasUsedAnnotation` | derived at analysis time from `annotation_started` events |

Delete `AnalyticsUserPropertySync` and `AnalyticsUserProperty+Keys`. Keep the protocol method
`setUserProperty` (unused) so a future actuation property can be added without re-plumbing.

### 2. Collection-time bucketing → **removed** (Policy #4)

Delete `AnalyticsBucketing` (`countBucket`). Every count param is logged **raw** (`int`,
treated as a metric): `score_deleted`, `score_added_to_playlist`,
`score_removed_from_playlist`, `tag_assigned`, `tag_unassigned`. Bucketing, if ever needed for
an in-console dimension, happens at analysis time.

### 3. New events

| Event | Params | Where |
|---|---|---|
| `screen_view` | `firebase_screen` (see values below) | each main `Screen`'s `onAppear` |
| `settings_snapshot` | one param per durable setting, current values (≤25, raw) | once at launch / app start |
| `library_snapshot` | raw counts: `score_count_total`, `score_count_mscz2/3/4`, `score_count_musicxml`, `score_count_midi`, `score_count_pdf`, `playlist_count`, `tag_count`, `favorite_count` | once at launch, after repository ready |

`firebase_screen` values (coarse, finalized against the actual `Screen` types during
implementation): `library`, `reader`, `score_info`, `settings`, `recently_deleted`,
`playlist_detail`, `tag_detail`. Note: SwiftUI is a single `UIHostingController`, so
`screen_view` is **not** auto-collected and must be emitted manually.

`settings_snapshot` params (representative; finalized against `SettingKey` + `ReaderPreferences`
during implementation, ≤25, raw — no rounding): `layout_mode`, `soundfont_preset`, `sort_order`,
`repeat_mode`, `playlist_continuation_mode`, `collapse_multi_measure_rests` (bool),
`honor_layout_breaks` (bool), `show_invisibles` (bool), `staff_size` (raw number),
`crash_reporting_enabled` (bool).

> "Current settings per user" = the latest `settings_snapshot` per user (BigQuery
> `ARRAY_AGG(... ORDER BY event_timestamp DESC LIMIT 1)`); `setting_changed` adds change
> history. Together they replace every per-setting user property.

### 4. Annotation → **session-aggregated** (Policy #6: no per-frame/high-frequency signals)

Replace the per-stroke `annotation_ink_committed` with a session-level pair:

| Event | Params | Where |
|---|---|---|
| `annotation_started` | — | annotation mode ENTER (unchanged trigger) |
| `annotation_ended` | `ink_strokes` (raw int — net strokes committed in the session), `duration_sec` (raw double) | annotation mode EXIT / teardown |

This mirrors the policy's `tracking_start` / `tracking_end` session model and removes the
high-frequency per-stroke stream.

### 5. `*_failed` events carry a categorized `reason` (Policy #5)

`score_import_failed` already uses a stable failure enum (`ScoreImportFailure`-style). Keep that
pattern; never log raw error strings.

### 6. Events kept as-is (names already compliant)

`score_imported`, `select_content` (score opened, GA4 recommended), `sort_changed`,
`favorite_toggled`, `search`, `playlist_created/renamed/deleted`, `playlist_reordered`,
`tag_created/renamed/deleted`, `playback_started`, `playback_completed`, `playback_control`,
`repeat_mode_changed`, `tempo_changed`, `layout_mode_changed`, `transpose_changed`,
`score_info_opened`, `share` (GA4 recommended, `content_type: "score"`), `setting_changed`,
`settings_opened`. (Counts inside these become raw per §2.)

## Events — should NOT track (guardrails)

| Don't track | Why |
|---|---|
| `first_open`, `session_start`, `session_id`, `user_engagement`, `app_update`, `os_update` | Firebase auto-collects; duplicates corrupt reports |
| Per-frame / real-time signals: live playback cursor position, scroll/seek scrub values, every play↔pause micro-toggle, per-stroke ink, pinch-zoom deltas | Floods the pipeline, ~zero decision value. Aggregate to session/action events |
| Raw high-cardinality value as a **grouping dimension** | GA4 `(other)`-collapses >500 distinct values. Keep raw as a *metric* param; don't register as a custom dimension |
| PII / user content: score title, composer, file name/path, lyrics, raw error strings | Policy + privacy. Use `reason` codes + provenance enums |
| Crashes / non-fatals as analytics events | Crashlytics owns this (Folino already routes import failures to Crashlytics non-fatals separately) |
| Reserved prefixes / reserved-name collisions | Rejected/overwritten by the SDK |

## User properties — **none** (deferred)

Folino ships **zero** custom user properties. Candidates, only if a concrete low-latency
in-Google-stack targeting need appears (each must pass the Policy #3 decision rule):

| Candidate | Value | Trigger to adopt |
|---|---|---|
| `crash_reporting_opt_out` / `analytics_opt_out` | true/false | only if a server-driven experiment must segment by consent with low latency |

Never set: `app_version`, `os_version`, `device_model`, `country`, `language` (auto dimensions);
any PII; anything wanted only for *analysis* (library composition, settings — those are events).

## Architecture / layering (unchanged boundaries)

- **Domain** owns `AnalyticsEvent` factories (adjusted), `AnalyticsSource`, domain-enum
  `analyticsValue` maps, and the new `screen` / `settingsSnapshot` / `librarySnapshot` /
  `annotationEnded` factories. Foundation-only; no Firebase.
- **Utility (UtilityCore)** keeps `Analytics`, `NoopAnalytics`, value types.
- **Infrastructure** keeps `FirebaseAnalyticsClient` (the only `FirebaseAnalytics` import) + gate.
- **Features** call sites: drop `setUserProperty` calls, unbucket counts, add `screen_view`
  on screen appear, swap annotation per-stroke for the session pair.
- **App** (`AppBootstrap`): replace the user-property push with `library_snapshot` +
  `settings_snapshot` event emission (behind the gate), at the same launch hooks.

## Files touched (anticipated — finalized in the plan)

| File | Change |
|---|---|
| `Domain/.../Analytics/AnalyticsBucketing.swift` | **delete** |
| `Domain/.../Analytics/AnalyticsUserPropertySync.swift` | **delete** |
| `Utility/.../UtilityCore/AnalyticsUserProperty+Keys.swift` | **delete** |
| `Domain/.../Analytics/AnalyticsEvent+Factories.swift` | edit — unbucket counts; add `screen`/`settingsSnapshot`/`librarySnapshot`/`annotationEnded`; drop `annotationInkCommitted` |
| `Domain/.../Analytics/AnalyticsScreen.swift` (or enum in factories) | **new** — `firebase_screen` value set + a `logScreen` convenience |
| `App/AppBootstrap.swift` | edit — `pushAnalyticsSnapshot` emits snapshot **events**, not user properties |
| Reader / Library / Settings call sites | edit — `screen_view` on appear; remove user-property calls; annotation session pair; raw counts |
| `Infrastructure/.../FirebaseAnalyticsClient.swift` | (likely unchanged; verify mapping) |
| Tests (Domain / Infrastructure / Feature) | edit — drop bucketing/user-property assertions; add snapshot/screen/annotation-session event-shape tests |

## Implementation notes

- Keep typed factories so event names can't drift; add `.screen(_:)`, `.settingsSnapshot(...)`,
  `.librarySnapshot(...)`, `.annotationEnded(strokes:duration:)`.
- Add an `analytics.logScreen(_:)` convenience → reserved `screen_view` + `firebase_screen`.
- Emit `library_snapshot` + `settings_snapshot` from the existing launch hooks in
  `AppBootstrap` (where `pushAnalyticsSnapshot` runs today), behind the consent gate.
- Numeric settings logged raw (delete the bucketing helper; no rounding at collection).
- Annotation: accumulate the session stroke count in the Reader annotation controller; emit
  `annotation_ended` on mode exit.

## Verification

- **Firebase DebugView** (`-FIRAnalyticsDebugEnabled`): exercise each flow; confirm event names
  + param names/types land, **no** PII, **no** collection-time buckets, raw counts present, and
  `screen_view`/`settings_snapshot`/`library_snapshot` fire at launch / on appear.
- **Consent gate**: toggle analytics off → confirm nothing forwards.
- **Unit tests** (Swift Testing): assert each VM action / launch hook builds the expected
  `AnalyticsEvent` (name + params); assert zero `setUserProperty` calls remain.
- **End-to-end** (after the user enables BigQuery export): derive "current settings/library per
  user" from the latest snapshot events; confirm no duplication of auto-collected events.

## Out of scope

- Enabling BigQuery export (owner: user, Firebase console — prerequisite, not retroactive).
- Android parity (Phase 6): the Android catalog re-uses this iOS taxonomy as source of truth;
  shared mapping per the iOS/Android parity rule. Not part of this spec.
