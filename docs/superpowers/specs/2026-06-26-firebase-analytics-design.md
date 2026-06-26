# Firebase Analytics — Design

**Date:** 2026-06-26
**Status:** Approved for planning

## Goal

Add Firebase Analytics to folino so we can answer two product questions:

1. **What do users do?** — fire a structured event for each meaningful user action
   (import, open/play, share, sort, playlist/tag CRUD, annotation, settings changes).
2. **Who are the users?** — set Firebase user properties for the settings snapshot,
   imported-score counts (by format), and current sort order, for cross-report
   segmentation.

The integration follows the existing Crashlytics pattern: a small Utility-layer
protocol, a Firebase adapter confined to Infrastructure, constructor injection from
the App composition root, and an opt-out toggle in Settings. iOS and Android ship
together, sharing one canonical event/property definition.

## Scope decisions (confirmed with user)

- **Consent: opt-out toggle**, mirroring Crashlytics. A new Settings toggle
  `privacyAnalyticsEnabled` (default **on**) gates collection. `IS_ANALYTICS_ENABLED`
  in `GoogleService-Info.plist` is flipped to `true`; the stored preference is
  authoritative and drives `Analytics.setAnalyticsCollectionEnabled` at launch and on
  toggle. Privacy nutrition label updated accordingly (usage/diagnostics data).
- **iOS + Android together.** The event/property *definitions* (names, params, value
  enums, bucketing rules) are the single source of truth and behave identically on
  both platforms. Only the thin SDK call site is platform-specific (Firebase iOS SDK
  vs. Firebase Android SDK).
- **Event granularity: semantic named events + params.** One event name per
  meaningful action, context carried in low-cardinality params. Firebase reserved
  event names (`share`, `select_content`, `search`) are used where they map, so GA4
  enriches them automatically. No generic `button_tap` catch-all.
- **Multi-path actions carry a `source` param.** Actions reachable from multiple UI
  surfaces (favorite, delete, share, add-to-playlist) fire from **every** path and
  tag the originating surface, so we can analyze where each action is initiated.
- **museScore version: major only.** Reuses the existing
  `ScoreSourceKind.museScore(majorVersion: Int)` Domain bridge — **no swift-sheet-music
  change required.** Full `4.7.2` patch capture is explicitly out of scope (see below).
- **No `item_id` in events.** Score-level per-user behavior is not tracked; format/
  aggregate analysis only.
- **Failures: split by purpose.** Import-failure *detail* (which file, which parse
  error) goes to Crashlytics `record(error:)` as a non-fatal. Import-failure *rate*
  (a lightweight `score_import_failed(format, reason)` event) goes to Analytics for
  funnel/conversion analysis. The two are intentional, not redundant.

## Out of scope (YAGNI)

- **Full `4.7.2` patch-version capture for mscz.** swift-sheet-music collapses the
  parsed `<museScore version>` to major (`MSCXVersion` v2/v3/v4) before it reaches
  Domain. Surfacing the raw version string would require a separate ssm change (its
  own example-app-verify → push → re-pin flow). Deferred as a possible follow-up;
  major is sufficient for the requested `score_count_mscz{2,3,4}` classification.
- **No `button_tap` exhaustive coverage.** Buttons without a meaningful semantic
  action (pure navigation chrome) are not individually logged. If exhaustive coverage
  is later wanted, a single auxiliary `button_tap(screen, button_id)` event can be
  added without disturbing the semantic catalog.
- **No `setUserID` / user-identifying metadata** (privacy).
- **Editor feature** has no actions yet (placeholder stub) — nothing to instrument.
- **Share extension target** analytics — app target only for v1.

## Architecture

Placement mirrors `CrashReporter` exactly — the ambient-service pattern.

```
UtilityCore     protocol Analytics (+ NoopAnalytics)
                AnalyticsEvent / AnalyticsUserProperty (canonical definitions)
   ▲      ▲
   │      └──────────── Features (each VM takes `any Analytics` via init)
   │
Infrastructure/Analytics   FirebaseAnalyticsClient: Analytics
   │                       (wraps FirebaseAnalytics SDK; owns collection toggle)
   ▲
  App  ── AppBootstrap builds the client after Crashlytics,
          injects `any Analytics` into Feature view models
```

Firebase imports stay confined to `Infrastructure/Analytics`. App imports only the
`Analytics` product + `UtilityCore`; it never imports `firebase-ios-sdk` directly.

### `UtilityCore` — the protocol and canonical definitions

```swift
public protocol Analytics: Sendable {
    /// Enable/disable collection. Persisted by the implementation across launches.
    func setCollectionEnabled(_ enabled: Bool)
    func log(_ event: AnalyticsEvent)
    func setUserProperty(_ value: String?, for property: AnalyticsUserProperty)
}
```

- `AnalyticsEvent` is a value type that owns its wire `name: String` and
  `parameters: [String: AnalyticsValue]`. Features construct it via type-safe
  factory functions (e.g. `.scoreImported(format:source:isDuplicate:)`) — raw event
  strings never leak into Feature code. This single file is the parity contract.
- `AnalyticsValue` = `.string | .int | .double | .bool`, mapped to the platform's
  parameter encoding by the adapter.
- `AnalyticsUserProperty` is an enum of the property keys (below), each knowing its
  wire name.
- `AnalyticsSource` enum (shared) encodes UI surfaces: `scoreRowMenu`, `bulkEdit`,
  `readerOverlay`, `scoreInfoSheet`, `recentlyOpened`, `favorites`, `playlist`,
  `tag`, `searchResult`, `libraryAll`.
- `NoopAnalytics` lives beside `NoopCrashReporter` for tests/previews.

### Bucketing helpers (shared, deterministic)

Counts and continuous values are bucketed to low-cardinality strings before leaving
Domain, so no raw PII-adjacent magnitudes reach Firebase:

- `countBucket(_:)` → `"0" | "1-5" | "6-20" | "21-50" | "51+"`.
- A4 reference and similar continuous values bucket to named tiers where surfaced.

These helpers live in Domain (pure, unit-tested) and are called by both platforms.

### Semantic versioning generalization

The existing `AppVersion` (`Domain/Models/AppVersion.swift`) is generalized to a
reusable `SemanticVersion` value type (`major.minor.patch`, `Comparable`,
`RawRepresentable`, `Sendable`). `AppVersion` becomes a typealias / thin wrapper so
`AppVersion.current` and existing call sites are unaffected.

> **Domain public-API change — requires confirmation before implementation.** The
> rename ripples to any `AppVersion` consumer. For analytics this type is *used* only
> to classify mscz major version (we already have `majorVersion: Int`), so the
> generalization is a tidy-up that serves the work, not a hard dependency. If the
> rename is judged too broad, fall back to using the existing `majorVersion: Int`
> directly and skip the generalization.

### Privacy gating

- New key `privacyAnalyticsEnabled` (Domain `PrivacySettingsKey`), default `true`.
- `PrivacySettingsSection` gains an "analytics / usage" toggle below crash reporting,
  with distinct copy (folino's internal feature names never surface in UI).
- `AppBootstrap` reads the stored value at launch and calls
  `analytics.setCollectionEnabled(_:)`; the toggle calls it live.
- `crash_reporting_enabled` and analytics consent are independent — a user may keep
  one on and the other off, which is itself a tracked dimension.

### Android parity

Android implements `Analytics` with the Firebase Android SDK (Kotlin). The
event/property *mapping* (names, params, value enums, bucketing) is driven by the
shared Swift definitions — Android does **not** re-derive the catalog. Per the parity
rules, the only Android-specific code is the Firebase Android SDK call site and its
wiring into the existing Android composition; the catalog, source enum, bucketing,
and consent semantics are shared. The Android opt-out toggle follows the existing
`android-crashlytics-opt-out` pattern.

## Event catalog

Reserved Firebase event names marked ★. All params are low-cardinality enums/bools/
bucketed ints. No raw titles, file paths, or search strings.

### Library

| Event | Trigger | Params |
| --- | --- | --- |
| `score_imported` | import succeeds | `format`, `source`(file_picker/share_ext), `is_duplicate`(bool), `musescore_version`(2/3/4/unknown — mscz only) |
| `score_import_failed` | import fails | `format`, `reason` |
| `select_content` ★ | open a score | `content_type`=score, `from`(library_all/recently_opened/favorites/playlist/tag/search_result) |
| `sort_changed` | sort picker changes | `sort_order`(date_added/title/composer/last_opened) |
| `score_deleted` | soft-delete | `source`, `mode`(single/bulk), `count` |
| `favorite_toggled` | ★/☆ from any surface | `enabled`(bool), `source`, `mode`(single/bulk) |
| `search` ★ | search executed | (no query text) |

### Playlists & tags (full CRUD)

| Event | Params |
| --- | --- |
| `playlist_created` / `playlist_renamed` / `playlist_deleted` | `source` |
| `playlist_reordered` | — |
| `score_added_to_playlist` | `source`, `count` |
| `score_removed_from_playlist` | `source`, `count` |
| `tag_created` / `tag_renamed` / `tag_deleted` | `source` |
| `tag_assigned` / `tag_unassigned` | `source`, `count` |

### Reader / playback

| Event | Trigger | Params |
| --- | --- | --- |
| `playback_started` | playback begins | `layout_mode`, `from`(same enum as select_content) |
| `playback_completed` | played to end | — |
| `playback_control` | pause / skip / seek | `action`(pause/prev/next/seek) |
| `repeat_mode_changed` | repeat toggle | `mode`(off/loop_all/ab_loop) |
| `tempo_changed` | tempo adjusted | `direction`(up/down) |
| `layout_mode_changed` | layout switch | `mode`(vertical/horizontal/page) |
| `transpose_changed` | transpose adjusted | `direction`(up/down/reset) |
| `score_info_opened` | info.circle tapped | `source` |
| `annotation_started` | annotation mode entered | — |
| `annotation_ink_committed` | **ink actually written** (true "pencil used" signal) | — |

### Share / export

| Event | Params |
| --- | --- |
| `share` ★ | `content_type`=score, `method`(mscz_v4/mscz_v3/pdf/midi/m4a), `source`, `mode`(single/bulk) |

### Settings / app

| Event | Params |
| --- | --- |
| `setting_changed` | `key`(setting key), `value`(stringified new value) — common for all toggles/pickers |
| `settings_opened` | — |
| `app_open` ★ | Firebase automatic — not emitted manually |

## User property catalog

Principle: a slot is spent only on a **stable dimension we'd segment all other
reports by**. Toggles are captured via `setting_changed` events, not properties.
~13 of 25 slots used, leaving headroom.

### Segmentation axes

| Property | Value |
| --- | --- |
| `layout_mode` | vertical / horizontal / page |
| `soundfont_preset` | lightweight / full |
| `current_sort_order` | date_added / title / composer / last_opened |
| `library_size_bucket` | 0 / 1-5 / 6-20 / 21-50 / 51+ |
| `crash_reporting_enabled` | true / false |
| `has_used_annotation` | true / false (set true once ink is ever committed) |

### Imported-score counts (by format, bucketed)

| Property | Value |
| --- | --- |
| `score_count_mscz2` | count bucket |
| `score_count_mscz3` | count bucket |
| `score_count_mscz4` | count bucket |
| `score_count_musicxml` | count bucket (includes .musicxml/.xml/.mxl) |
| `score_count_midi` | count bucket |
| `score_count_pdf` | count bucket |

Recomputed at launch and after any import/delete. mscz rows are split by
`majorVersion` from the existing Domain bridge; rows without a detected version fall
into a sensible default (treated as v4, matching ssm's detection default).

### Dropped from properties (captured as events instead)

`metronome`, `pip`, `keep_awake`, `seek_bar`, `collapse_mmrest`,
`playlist_continuation`, `repeat_mode`, `a4_reference`, `playlist_count`,
`tag_count` — all reachable via `setting_changed` / count queries if needed later.
`analytics_enabled` is **not** a property (it is necessarily true whenever an event
is received).

## Error handling

- Analytics calls are best-effort and never throw to callers; the adapter swallows
  SDK errors (a failed log must not affect UX).
- When collection is disabled, `log` / `setUserProperty` are no-ops at the adapter
  boundary (in addition to the SDK-level disable), so gating is defense-in-depth.
- `NoopAnalytics` is used in all tests and previews — no real Firebase calls in CI.

## Testing

- **Domain:** unit-test `SemanticVersion` parsing/compare, `countBucket`, and the
  format→property mapping (incl. mscz major split and the no-version default).
- **Utility:** verify `AnalyticsEvent` factories emit the exact wire `name`/params
  expected (locks the parity contract).
- **Features:** view-model tests assert the right `AnalyticsEvent` is logged with the
  right `source`/params for each action, using a recording `SpyAnalytics` fake. This
  covers the multi-path `source` tagging (favorite/delete/share from each surface).
- **Consent:** assert that toggling `privacyAnalyticsEnabled` calls
  `setCollectionEnabled` and that a disabled client logs nothing.
- **Android:** mirror the Feature-level event assertions against the shared catalog.
- No live Firebase assertions; the SDK call site is verified by manual DebugView
  inspection during bring-up, not automated tests.

## Open questions / dependencies

1. **`SemanticVersion` generalization** is a Domain public-API rename — confirm before
   implementing, or fall back to `majorVersion: Int`.
2. **Privacy nutrition label** must be updated in App Store Connect / Play Data Safety
   to declare usage/diagnostics collection before release.
3. Android wiring reuses the Crashlytics opt-out scaffolding; confirm the toggle copy
   matches the iOS string.
