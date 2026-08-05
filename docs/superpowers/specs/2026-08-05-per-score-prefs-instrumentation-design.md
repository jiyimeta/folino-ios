# Per-Score Reader Preferences — "changed vs. untouched" Instrumentation

**Date:** 2026-08-05
**Status:** Approved (design), pending spec review
**Builds on:** `docs/superpowers/specs/2026-06-29-analytics-events-first-design.md` (events-first taxonomy; the
plumbing, naming rules, and BigQuery-first analysis workflow established there are assumed throughout).

## Goal

For the per-score Reader preferences we want to answer, from analytics alone:

- **(a)** how many **scores** have each setting changed,
- **(b)** how many **users** have changed each setting,
- **(c)** the distribution of the final settled **value**,
- **(d)** — the critical one — whether a value is what it is because the user **explicitly set it**, or because it is
  still the **untouched default**.

(d) is the input the planned device-class staff-size default needs: before choosing an iPad default we must know how
many iPad users actually touch staff size, and what they settle on, without counting the thousands of rows that merely
echo the seeded `14`.

## Context — why (d) is impossible today

Four properties of the current implementation conspire to erase the changed/untouched distinction:

1. **Row existence only means "was opened."** `ReaderPreferences.reconcilingAuthoredHidden`'s `guard let stored else`
   branch (`Packages/Domain/Sources/Domain/Models/ReaderPreferences+AuthoredVisibilitySeed.swift:20-27`) returns
   `shouldPersist: true` for every score that has no stored row, and `ReaderPreferencesStore.loadOrSeed` writes that
   default-valued row through on first open (`Packages/Features/Reader/Sources/Reader/ReaderPreferencesStore.swift:51-53`).
   Every opened score therefore has a row full of defaults.
2. **Non-Optional fields cannot say "never touched."** `staffSize` (seeded 14), `honorLayoutBreaks` (default `true`,
   `ReaderPreferences.swift:89`), `masterVolume` (default `1.0`, line 93), and `transposeSemitones` (default `0`, line
   93) store a concrete value either way. The fields that are already Optional — `tempoMultiplier`, `a4ReferenceHz`,
   `abRepeat` (`ReaderPreferences.swift:54,63,73`) — and the override dictionaries (`staffProgramOverrides`,
   `staffVolumeOverrides`, `staffClefOverrides`, empty when untouched) already carry the distinction; the design below
   extends their `nil`/empty == untouched convention to the rest of the struct rather than inventing a new mechanism.
3. **`hiddenStaves` conflates two authors.** A non-empty set can come from the score's authored
   `<Part><show>0</show>` seed (`ReaderPreferences+AuthoredVisibilitySeed.swift:14-36`), not from the user.
4. **"Compare against the default at analysis time" is permanently broken by the roadmap.**
   `Packages/Features/Reader/Sources/Reader/Screens/ReaderRootScreen.swift:166` reads
   `let initialDefault: Double = 14 // TBD: device-class override (follow-up)` — once the default varies by device
   class (and possibly by app version), no query can reconstruct which stored `14` was a choice and which was a seed.

## Motivating measurements (verified against GA4 property 543062540 / BigQuery export)

- **No event covers these settings today.** There is no analytics event for staff size or honor-layout-breaks at all;
  `settings_snapshot` (`AnalyticsEvent+Factories.swift:210-238`) covers only global settings, and the per-score events
  that do exist (`tempo_changed`, `transpose_changed`, `AnalyticsEvent+Factories.swift:138-140,152-154`) log a
  direction, not a settled value, and cannot be joined back to a score population.
- **Per-launch, per-changed-score volume is negligible.** Library size per user: median 4 scores, p90 18, p99 37,
  max 152. Launch frequency: mean 0.31/day, p99 1.79/day. One event per changed score at launch is at worst a few
  dozen events per launch for outlier users.
- **Device dimensions come free, screen size does not.** `deviceCategory` splits mobile 1,653 users / tablet 166
  (iPad = 9.1%) and is attached to every event automatically. `mobileDeviceModel` resolves iPad variants but 28% of
  iPad users report the generic `"iPad"`, and `screenResolution` is `(not set)` on iOS app streams — so the effective
  layout width must be carried by our own event parameter (see `screen_width_pt` below).

## Design overview (approach B)

Make "untouched" representable in the Domain model itself: the per-score scalar fields become Optional, `nil` meaning
"the user never set this — resolve to the current default." Persistence stores the `nil` (nullable columns, migration
v16), the seeded first-open write is elided when it would carry no information, authored-hidden staves get their own
column so user intent is separable, and a new launch-time `score_prefs` event emits one event per score that has any
non-`nil` preference — with each parameter present only when its value is non-`nil`, so "param present" == changed in
BigQuery.

This is deliberately **not** analytics-only plumbing. The current behavior bakes `14` into every opened score's row,
so when the device-class default ships it would never reach any existing score; an untouched score should follow
whatever the current default is, and `nil` is what makes that possible. The model also becomes self-consistent:
`tempoMultiplier` and `a4ReferenceHz` already work exactly this way, down to the Reader normalizing a saved
`tempoMultiplier` of exactly 1.0 back to `nil` "so the override doesn't outlive the user's intent"
(`ReaderPreferences.swift:51-53`).

### Discrepancy vs. the original sketch: repeat mode is global, not per-score

The initial problem statement listed `repeatMode` as a fifth field to Optional-ize. The code says otherwise: the
repeat mode was migrated from per-score to a single sticky global (`RepeatModel.mode` persists through
`RepeatModeStorage` on every change, `Packages/Features/Reader/Sources/Reader/RepeatModel.swift:15-22`;
`RepeatModel.sync(from:)` reads the global key and ignores `prefs.repeatMode`, lines 59-66; the one-shot per-score →
global migration lives in `App/AppBootstrap.swift:280-293`). `ReaderViewModel.wireRepeatModel` persists only the A–B
endpoints per score (`ReaderViewModel.swift:315-323`). The Domain field `ReaderPreferences.repeatMode`
(`ReaderPreferences.swift:61`) and its `repeat_mode` column are a legacy remnant with **no user write path** — every
save re-writes whatever was loaded (`'off'` for post-migration rows).

Consequently: `repeatMode` stays non-Optional and untouched by this work, and `score_prefs` carries **no**
`repeat_mode` parameter — the global mode is already covered by `settings_snapshot` (`AppBootstrap.swift:199`) and
`repeat_mode_changed` (`ReaderViewModel.swift:329-331`). Dropping the dead column is left to a future cleanup; v16
copies it through unchanged.

## 1. Domain — four fields become Optional, `nil` == untouched

In `Packages/Domain/Sources/Domain/Models/ReaderPreferences.swift`:

| Field | Today | Becomes | Static default |
| --- | --- | --- | --- |
| `staffSize` (line 36) | `Double`, seeded 14 | `Double?` | none — injected (device-class plan) |
| `honorLayoutBreaks` (line 59) | `Bool`, default `true` | `Bool?` | `defaultHonorLayoutBreaks = true` |
| `masterVolume` (line 67) | `Double`, default 1.0 | `Double?` | `defaultMasterVolume = 1.0` |
| `transposeSemitones` (line 70) | `Int`, default 0 | `Int?` | `defaultTransposeSemitones = 0` |

Resolution is owned by the type so call sites need no injection:

- `effectiveHonorLayoutBreaks: Bool`, `effectiveMasterVolume: Double`, `effectiveTransposeSemitones: Int` — computed
  accessors returning `field ?? Self.default*`.
- `effectiveStaffSize(default:) -> Double` — staff size alone takes the default as an argument, because its default is
  the one that becomes device-dependent (`ReaderRootScreen.swift:166`); baking a static `14` into Domain would
  recreate the exact problem this design removes. The Reader already threads `defaultStaffSize` from the screen down
  through `ReaderViewModel.init` (`ReaderViewModel.swift:190,210`), so the value is at hand wherever resolution
  happens.

**Clamping must become `map`-based so it never materializes a value out of `nil`.** The `init` currently runs
`self.staffSize = min(max(staffSize, ...))` and friends unconditionally (`ReaderPreferences.swift:99,112-113`); each
becomes the `Optional.map` form the type already uses for `tempoMultiplier` (line 106-108) and `a4ReferenceHz` (line
114). This matters doubly because every mutation on both platforms re-seats through this `init`
(`ReaderPreferencesStore.mutate`, `ReaderPreferencesStore.swift:59-81`; `ReaderPreferencesReducer.reseat`,
`Packages/Features/Library/Sources/FolinoLibraryJNI/ReaderPreferencesReducer.swift:12-21`) — a clamp that turns `nil`
into a number would silently mark every score touched on its next save.

Adjacent Domain changes:

- `init` parameter `staffSize:` becomes `Double? = nil`; `honorLayoutBreaks`/`masterVolume`/`transposeSemitones`
  defaults become `nil` (`ReaderPreferences.swift:83,89,92-93`).
- `hasStaffBoundOverrides` (line 120-126): `transposeSemitones != 0` becomes `(transposeSemitones ?? 0) != 0`, so an
  explicit `.some(0)` still doesn't count as staff-bound — identical behavior to today.
- `clearingStaffBoundOverrides()` (line 131-140): `copy.transposeSemitones = 0` becomes `= nil` — after a PDF re-read
  the transposition is genuinely "untouched again," and the pass-through in
  `ReaderViewModel+PDFReread.swift:93` needs no change beyond the type.
- `reconcilingAuthoredHidden` (`ReaderPreferences+AuthoredVisibilitySeed.swift:14-19`): the `defaultStaffSize:`
  parameter is **removed** — a fresh seed row now carries `staffSize: nil`. (The Android bridge's current argument for
  it was already circular: it passes `prefs.staffSize` of the very row being reconciled,
  `ReaderPreferencesBridge.swift:79`.) This is a public Domain API signature change with exactly two callers
  (`ReaderPreferencesStore.swift:44-49`, `ReaderPreferencesBridge.swift:75-80`).
- Custom Codable (`ReaderPreferences.swift:151-188`): the four fields move to `decodeIfPresent` with **no** default
  fallback (missing key → `nil`). See §8 for the Android legacy-blob consequence.

`ReaderPreferencesStore` no longer needs its `defaultStaffSize` (`ReaderPreferencesStore.swift:14,18,26`) — its
placeholder and seed both become `staffSize: nil`. `ReaderViewModel` keeps its copy for the view-model layer (§2).

## 2. The trap — the view models must also carry "untouched"

This is the main correctness risk of the whole design, and it gets its own regression test (§9).

`ReaderViewModel.wireLayoutModel()`'s `onChange` writes `staffSize`, `honorLayoutBreaks`, `hiddenStaves`, and
`staffClefOverrides` **together** on every layout change (`ReaderViewModel.swift:249-254`). If the Domain type went
Optional but `LayoutSettingsModel` kept a resolved `staffSize: Double = 14`
(`Packages/Features/Reader/Sources/Reader/LayoutSettingsModel.swift:14`), then the moment a user changed only a clef
override, the shared `onChange` would write the resolved `14.0` back into `prefs.staffSize` — permanently marking
staff size as touched. The same shape recurs in `wireMasterVolumeModel` (`ReaderViewModel.swift:278-286`) and
`wireTransposeModel` (lines 288-299), though those callbacks write single fields.

Therefore each sub-model holds the raw Optional as its persistent slice and exposes a resolved value for the UI —
exactly the split `TempoModel` already has (its persistent `multiplier` is Optional and the VM reads
`tempoModel.effectiveMultiplier`, `ReaderViewModel.swift:472`):

- **`LayoutSettingsModel`** — stored `staffSize: Double?` and `honorLayoutBreaks: Bool?`; new
  `defaultStaffSize: Double` injected by `ReaderViewModel` at wiring time; computed `effectiveStaffSize: Double` and
  `effectiveHonorLayoutBreaks: Bool`. `sync(from:)` (lines 26-31) copies the raw Optionals.
  `incrementStaffSize`/`decrementStaffSize` (lines 33-45) start from `effectiveStaffSize` and write a non-`nil`
  stepped value; `setHonorLayoutBreaks` compares against the effective value and writes non-`nil`. The UI read sites
  inside Reader move to the effective accessors: `VisualInspectorScreen.swift:110,169-171,186` (toggle binding,
  stepper binding + label), `ScoreContentView.swift:94-95,110-111,125-126`, `ReaderViewModel+SessionWiring.swift:49`,
  and `recomputeVisibleScore`'s inputs stay as-is (they read the model, not prefs). Side benefit: the model's
  incoherent initial `honorLayoutBreaks = false` (line 15, vs. Domain default `true`) disappears — `nil` resolves
  correctly before the first `sync`.
- **`MasterVolumeModel`** — stored `value: Double?` (`MasterVolumeModel.swift:15`); `displayValue` becomes
  `liveValue ?? value ?? ReaderPreferences.defaultMasterVolume` (line 26-28); `commitValue` (lines 44-53) writes the
  clamped non-`nil` value even when it lands exactly on 1.0 (an explicit choice is an explicit choice — see the
  forward-semantics note below); `resetValue` (lines 55-61) writes `nil` — the reset affordance means "back to
  default," and "follow the default" is precisely what `nil` encodes. Engine forwarding keeps sending the resolved
  number.
- **`TransposeModel`** — stored `semitones: Int?` (`TransposeModel.swift:13`); computed `effectiveSemitones: Int`;
  `setSemitones` (lines 24-30) compares/clamps against the effective value and writes non-`nil`; `reset()` (lines
  33-35) writes `nil` instead of calling `setSemitones(0)`. `ReaderViewModel`'s direction-baseline read
  (`ReaderViewModel.swift:473`) and `recomputeVisibleScore` (line 442) move to `effectiveSemitones`.

Forward semantics worth stating: after this change, a user who *explicitly* sets a control to the default value (e.g.
toggles honor-layout-breaks off and back on) is stored as `.some(default)` and correctly counts as "touched" — the
lossy default-equals-untouched collapse happens only once, in the v16 conversion of pre-existing rows (§4). The only
paths that write `nil` are the dedicated reset affordances, where "stop overriding" is the user's actual intent.

## 3. Resolution points are few (verified)

Direct reads of the four fields were enumerated across `Packages/` and `App/`. Nearly all are pass-throughs that keep
carrying the Optional and need only type-level changes:

- record ↔ domain: `ReaderPreferencesRecord.init(domain:)`/`toDomain()`
  (`Packages/Infrastructure/Sources/Persistence/Records/ReaderPreferencesRecord.swift:48,73-77,106-122`),
- the mutate/reduce re-seats: `ReaderPreferencesStore.mutate` (`ReaderPreferencesStore.swift:62-78`),
  `ReaderPreferencesReducer.reseat` and its setters (`ReaderPreferencesReducer.swift:12-57`),
- the PDF re-read copy (`ReaderViewModel+PDFReread.swift:93`).

The places that actually resolve `?? default` are only:

1. `LayoutSettingsModel` (staff size + breaks), `MasterVolumeModel`, `TransposeModel` — via the effective accessors of
   §2.
2. `PlaybackPreferences.initial` (`Packages/Features/Reader/Sources/Reader/PlaybackPreferences+Initial.swift:39,44`) —
   `masterVolume` and `transposeSemitones` feed the non-Optional `PlaybackPreferences`
   (`Packages/Domain/Sources/Domain/Models/PlaybackPreferences.swift:61,69`), which deliberately stores resolved
   values ("never `nil`, so the engine always has an explicit target," line 62-64). It already resolves
   `tempoMultiplier ?? 1.0` (line 37); the two new `??` sit beside it.
3. `ReaderPreferencesBridge`'s wire projection (`ReaderPreferencesBridge.swift:191-202`) and its `open` placeholder
   (lines 53-61) — see §8.

Everything downstream reads already-resolved values and does not change: `LivePlaybackController` consumes
`PlaybackPreferences` (`Packages/Infrastructure/Sources/Audio/LivePlaybackController.swift:194-196`), the score
containers take plain parameters fed from the layout model (`VerticalScoreContainer.swift:481-484` and the Horizontal/
Paged twins), the PiP snapshot is built from the layout model (`ReaderViewModel+SessionWiring.swift:49`,
`ReaderPiPSession.swift:160-165`), and the inspector screens bind to the models (§2). The original sketch also listed
"the repeat-mode apply site" — it does not exist (`RepeatModel.sync` reads the global key, `RepeatModel.swift:62-66`);
see the discrepancy note above.

## 4. Persistence — migration v16

`Packages/Infrastructure/Sources/Persistence/Database/Migrations.swift` registers v16 after v15 (`Migrations.swift:
7-25`). Every prior migration is `ALTER TABLE ... ADD COLUMN` (v2 creates the table with `staff_size REAL NOT NULL`,
lines 198-207; v4 adds `honor_layout_breaks ... NOT NULL DEFAULT 1`, lines 220-225; v9 `master_volume ... NOT NULL
DEFAULT 1.0`, lines 283-288; v11 `transpose_semitones ... NOT NULL DEFAULT 0`, lines 305-314) — but SQLite cannot drop
a `NOT NULL` constraint in place, so v16 is this file's first table rebuild: create `reader_preferences_new` with the
same shape except the four columns nullable plus the new `authored_hidden_staves` column (§6), `INSERT ... SELECT`
with the conversions below, `DROP TABLE reader_preferences`, `ALTER TABLE ... RENAME`. The rebuild must reproduce the
`score_item_id` primary key and its `REFERENCES score_items(id) ON DELETE CASCADE` (v2, line 202); GRDB's migrator
disables foreign keys during a migration and re-checks afterwards, so the standard rebuild recipe is safe. Written as
raw `db.execute(sql:)` like every neighbor.

Row conversion — a stored default is reclassified as untouched:

| Column | Stored value | Converts to |
| --- | --- | --- |
| `staff_size` | `14` | `NULL` |
| `staff_size` | anything else | kept |
| `honor_layout_breaks` | `1` | `NULL` |
| `honor_layout_breaks` | `0` | kept |
| `master_volume` | `1.0` | `NULL` |
| `master_volume` | anything else | kept |
| `transpose_semitones` | `0` | `NULL` |
| `transpose_semitones` | anything else | kept |
| `repeat_mode` | any | kept as-is (legacy column, not Optional-ized — see discrepancy note) |
| `authored_hidden_staves` (new) | — | copy of `hidden_staff_ids` (§6) |

**Known, accepted tradeoff:** a user who explicitly chose the default value before v16 is reclassified as untouched.
That is the correct *forward* behavior — they should follow a changed default, which is what an explicit-default
chooser almost certainly wants — and its only analytical cost is that early numbers slightly under-report "changed."
The conversion is also what keeps the instrumentation honest: without it, every pre-v16 row would read as fully
changed (see Known limitations).

`ReaderPreferencesRecord` mirrors the nullability (`staffSize: Double?`, `honorLayoutBreaks: Bool?`, `masterVolume:
Double?`, `transposeSemitones: Int?`, `ReaderPreferencesRecord.swift:13,18,22-23`) and passes Optionals through
unchanged in both directions. Tests get an `upToV15` aggregate migrator following the existing `upToV2`…`upToV8`
pattern (`Migrations.swift:36-116`).

## 5. Stop `loadOrSeed`'s pointless write

Once an all-`nil` row carries no information, writing it is waste. `reconcilingAuthoredHidden`'s no-stored branch
(`ReaderPreferences+AuthoredVisibilitySeed.swift:20-27`) returns `shouldPersist: !authoredHiddenStaves.isEmpty` — a
fresh row is persisted only when there are authored-hidden staves (and, per §6, their authored provenance) to record.
`ReaderPreferencesStore.loadOrSeed` (`ReaderPreferencesStore.swift:40-55`) needs no change beyond the signature: the
unpersisted seed value still lands in `preferences` and is distributed to the sub-models
(`ReaderViewModel.loadOrSeedPreferences`, `ReaderViewModel.swift:461-474`); the first real mutation persists the full
row via `mutate`'s whole-struct save (`ReaderPreferencesStore.swift:80`, an upsert —
`LiveScoreLibraryRepository.saveReaderPreferences` uses GRDB `save`, `LiveScoreLibraryRepository.swift:347-355`).
Fewer writes on every first open of every score is a side benefit; the analytical point is that after this change,
**row existence approximates "has at least one changed thing"** instead of "was opened once."

The Android bridge's `open` has the same pointless write ("writes them through so the row exists," 
`ReaderPreferencesBridge.swift:50-62`) and drops it identically: hold the seed in memory, save on first mutation.

## 6. Separate user-hidden staves from authored-hidden

`hiddenStaves` stays the single source of truth for what is hidden; what's missing is provenance. Add
`authoredHiddenStaves: Set<StaffAddress>` to `ReaderPreferences` (persisted as `authored_hidden_staves`, JSON-encoded
`[StaffAddress]` exactly like `hidden_staff_ids`, `ReaderPreferencesRecord.swift:5-7,49-51`), written by
`reconcilingAuthoredHidden`:

- fresh seed → `authoredHiddenStaves = authoredHiddenStaves` (the score-derived set),
- the one-time back-fill branch (`ReaderPreferences+AuthoredVisibilitySeed.swift:29-35`) → records the set alongside
  the union,
- **and a new refresh rule:** since the authored set is score-derived ground truth handed in on every open
  (`ReaderPreferencesStore.loadOrSeed`, `ReaderPreferencesStore.swift:40-49`), a stored row whose
  `authoredHiddenStaves` differs from the score's current set is updated (and persisted) with the current set —
  without touching `hiddenStaves`, so user reveals stay sticky. This makes the column self-healing after v16 and after
  a PDF re-read renumbers staves.

v16 initializes `authored_hidden_staves` to a copy of `hidden_staff_ids`: for pre-existing rows we cannot distinguish
authored from user hides, so all current hides are classified authored — the conservative, under-reporting direction,
consistent with §4's conversion — and the refresh rule corrects each row on its next open (a PDF's next open passes
the empty set, reclassifying its hides as user intent).

User intent is then derivable per row: **user-hidden** = `hiddenStaves.subtracting(authoredHiddenStaves)` (staves the
user hid), **user-revealed** = `authoredHiddenStaves.subtracting(hiddenStaves)` (authored-hidden staves the user
turned back on). Both are reported as counts (§7) — addresses would be meaningless across scores.

## 7. Analytics — the `score_prefs` event

One new typed factory in the Domain catalog (`AnalyticsEvent+Factories.swift`), emitted at launch from
`AppBootstrap.pushAnalyticsSnapshot` (`App/AppBootstrap.swift:170-207`, called at line 153 once the repository is
ready, behind the same consent gate): **one event per score that has ANY non-`nil` / non-empty per-score preference.**
Scores whose row is absent or all-untouched emit nothing.

No score identifier is sent. The requirements (a)–(d) are all population-level; omitting the ID keeps the payload free
of anything score-identifying (titles and filenames are banned outright by the events-first policy, and even an opaque
per-score ID is a correlation handle we don't need).

**The crucial mechanic: a parameter is included only when its underlying value is non-`nil` (non-empty for sets and
override dictionaries).** In BigQuery, "param present" == changed, and the param's value is the settled value. That
single rule delivers all of (a), (b), (c), and (d) — no sentinel values, no separate `*_changed` booleans. The rule
only ever errs toward absence: `staff_size` is suppressed for legacy Android blobs, where a seed and a choice are
genuinely indistinguishable (see Known limitations).

| Parameter | Type | Present when | Value |
| --- | --- | --- | --- |
| `staff_size` | Int | `staffSize != nil` | the set size in points, rounded |
| `honor_layout_breaks` | Bool | `honorLayoutBreaks != nil` | the explicit setting (both `true` and `false` occur) |
| `master_volume_pct` | Int | `masterVolume != nil` | percent, rounded to 10% steps (0…300) |
| `transpose_semitones` | Int | `transposeSemitones != nil` | −7…+7 |
| `tempo_multiplier_pct` | Int | `tempoMultiplier != nil` | percent, rounded to 10% steps (50…200) |
| `a4_reference_hz` | Int | `a4ReferenceHz != nil` | rounded to whole Hz |
| `hidden_staff_count` | Int | user-hidden set non-empty | `hiddenStaves.subtracting(authoredHiddenStaves).count` |
| `revealed_staff_count` | Int | user-revealed set non-empty | `authoredHiddenStaves.subtracting(hiddenStaves).count` |
| `program_override_count` | Int | `!staffProgramOverrides.isEmpty` | count |
| `volume_override_count` | Int | `!staffVolumeOverrides.isEmpty` | count |
| `clef_override_count` | Int | `!staffClefOverrides.isEmpty` | count |
| `screen_width_pt` | Int | always | effective width bucket (below) |

Twelve parameters, well under GA4's 25-per-event limit. (The sketch's `repeat_mode` is dropped per the discrepancy
note; `revealed_staff_count` is added so the hid/reveal split of §6 is actually reportable.)

**On bucketing:** rounding `master_volume_pct` / `tempo_multiplier_pct` to 10% and snapping `screen_width_pt` to a
breakpoint is a deliberate, documented exception to the events-first "log numeric params raw" rule (policy #4 in the
2026-06-29 spec). These three are continuous-slider / continuous-geometry values whose sub-bucket precision carries no
decision value, and (c) is explicitly a distribution question — the bucket *is* the unit of analysis. Counts and the
discrete params (`staff_size`, `transpose_semitones`, `a4_reference_hz`) stay raw.

**`screen_width_pt`** is the app window's effective width in points at emission time, floored to the largest entry of
`320 / 375 / 390 / 430 / 744 / 834 / 1024 / 1366` that does not exceed it (below 320 reports 320). Rationale: choosing
a device-class staff-size default needs the effective point width the layout actually gets, not the model name —
iPhone 16e and 17 Pro Max differ, iPad Split View / Stage Manager changes the effective width at runtime, and a width
bucket needs no per-model mapping table as new hardware ships. The floor semantics make a 507 pt Split View window
report 430 — "an iPhone-class width" — which is exactly the layout-relevant fact. iPad-vs-iPhone itself needs no
parameter: GA4 attaches `deviceCategory` to every event automatically. The App layer measures the width (it owns the
window scene) and passes it to the Domain factory, which owns the bucketing so both platforms share it.

**Conventions** (matching the existing catalog): a typed factory `AnalyticsEvent.scorePrefs(...)` taking the Domain
`ReaderPreferences` (plus the width), building the parameter dictionary conditionally — names can't drift, and every
value is funneled through this one low-cardinality stringification point, the same discipline `SettingChangeLogger`
enforces for `setting_changed` (`Packages/Features/Settings/Sources/Settings/Screens/SettingChangeLogger.swift:4-19`).
No raw or free-text value (score title, playlist name, tag name) can reach a parameter because the factory accepts
none.

**Emission plumbing:** `ScoreLibraryRepository` gains `func allReaderPreferences() async throws ->
[ReaderPreferences]` next to the existing pair (`Packages/Domain/Sources/Domain/Protocols/ScoreLibraryRepository.swift:
53-57`), implemented with a plain table fetch in `LiveScoreLibraryRepository`
(`LiveScoreLibraryRepository.swift:333-345` shows the shape). This is an additive Domain-protocol change; the fakes in
Feature/Infrastructure tests grow one method. `pushAnalyticsSnapshot` filters the rows to live score items
(`repository.scoreItems` publishes non-trashed items only, `LiveScoreLibraryRepository.swift:119-128`) so the
numerator matches the `library_snapshot.score_count_total` denominator, then logs one event per qualifying row, after
`library_snapshot` / `settings_snapshot` (`AppBootstrap.swift:174-206`).

### BigQuery — the queries this design must answer (self-verification)

`score_prefs` fires every launch, so analysis takes each user's **latest launch** (grouped by `ga_session_id`).
`staff_size` is the exemplar; every other parameter substitutes its key (Bool params surface as 0/1 in `int_value`).

**(a) + (b) — scores and users with the setting changed:**

```sql
WITH events AS (
  SELECT
    user_pseudo_id,
    (SELECT value.int_value FROM UNNEST(event_params) WHERE key = 'ga_session_id') AS session_id,
    event_timestamp,
    (SELECT value.int_value FROM UNNEST(event_params) WHERE key = 'staff_size') AS staff_size
  FROM `analytics_543062540.events_*`
  WHERE event_name = 'score_prefs'
),
sessions AS (
  SELECT user_pseudo_id, session_id,
         MAX(event_timestamp) AS last_ts,
         COUNTIF(staff_size IS NOT NULL) AS scores_changed
  FROM events
  GROUP BY user_pseudo_id, session_id
),
latest AS (
  SELECT *, ROW_NUMBER() OVER (PARTITION BY user_pseudo_id ORDER BY last_ts DESC) AS rn
  FROM sessions
)
SELECT
  SUM(scores_changed)         AS scores_with_staff_size_changed,  -- (a)
  COUNTIF(scores_changed > 0) AS users_with_staff_size_changed    -- (b)
FROM latest
WHERE rn = 1
```

**(c) — distribution of the settled value (join `deviceCategory` or `screen_width_pt` in as needed):**

```sql
WITH events AS (
  SELECT
    user_pseudo_id,
    (SELECT value.int_value FROM UNNEST(event_params) WHERE key = 'ga_session_id') AS session_id,
    event_timestamp,
    (SELECT value.int_value FROM UNNEST(event_params) WHERE key = 'staff_size') AS staff_size
  FROM `analytics_543062540.events_*`
  WHERE event_name = 'score_prefs'
),
latest_session AS (
  SELECT user_pseudo_id, session_id FROM (
    SELECT user_pseudo_id, session_id,
           ROW_NUMBER() OVER (PARTITION BY user_pseudo_id ORDER BY MAX(event_timestamp) DESC) AS rn
    FROM events GROUP BY user_pseudo_id, session_id
  ) WHERE rn = 1
)
SELECT e.staff_size, COUNT(*) AS scores, COUNT(DISTINCT e.user_pseudo_id) AS users
FROM events AS e
JOIN latest_session USING (user_pseudo_id, session_id)
WHERE e.staff_size IS NOT NULL
GROUP BY e.staff_size
ORDER BY e.staff_size
```

**Denominator** for "what fraction of scores": the same user's latest `library_snapshot.score_count_total`
(`AnalyticsEvent+Factories.swift:242-259`) — `ARRAY_AGG(... ORDER BY event_timestamp DESC LIMIT 1)` per user, summed,
divided into (a). (d) is answered structurally: presence == explicitly set, absence == untouched default.

GA4 custom-dimension registration for these params is **optional and deferred** — the BigQuery export captures every
param regardless of registration (registration is non-retroactive and only feeds the console UI, which our
programmatic workflow doesn't use).

## 8. Android parity

Per the parity rule (CLAUDE.md: share the logic, never reimplement a divergent Kotlin copy), nothing user-facing
changes on Android, and no Kotlin logic is written:

- **`ReaderPreferencesStateWire` stays non-Optional and Compose is untouched.** It is a resolved scalar projection by
  design (`Packages/Features/Library/Sources/FolinoLibraryJNI/ReaderPreferencesWire.swift:15-41`, sentinel doc lines
  3-5). What changes is where resolution happens: `ReaderPreferencesBridge.republish`
  (`ReaderPreferencesBridge.swift:191-202`) projects `prefs.effectiveStaffSize(default: openDefaultStaffSize)`,
  `prefs.effectiveHonorLayoutBreaks`, `prefs.effectiveMasterVolume`, `prefs.effectiveTransposeSemitones` — the bridge
  retains the `defaultStaffSize` it already receives in `open(scoreId:defaultStaffSize:)`
  (`ReaderPreferencesBridge.swift:53`) for that resolution. The `open` placeholder/seed uses `staffSize: nil` (lines
  45, 59) and no longer writes the seed row (§5); `seedAuthoredHidden` drops its now-removed `defaultStaffSize:`
  argument (line 79).
- **`ReaderPreferencesReducer` setters keep writing non-`nil`** (`ReaderPreferencesReducer.swift:23-57` — a Kotlin-side
  set is always an explicit user action) and the `reseat` pass-through carries the Optionals (lines 12-21). If the
  Android UI later grows reset affordances they call new `clear*` reducer functions writing `nil`; none exist today.
- **Legacy JSON blobs need the v16 conversion too**, and they have no migration runner — the blob store is opaque
  Kotlin persistence (`ReaderPreferencesBridge.swift:5-8`). The Codable layer versions the payload instead: `encode`
  adds a `schemaVersion: 2` key; `init(from:)` treats a missing `schemaVersion` as a legacy blob and normalizes
  default-valued fields to `nil` (14 / `true` / 1.0 / 0 → `nil`, mirroring §4's table), while `schemaVersion >= 2`
  blobs take present values as authoritative. This keeps the conversion one-time in effect — without the marker, a
  decode-time normalization would forever collapse an explicitly-re-chosen default back to untouched. iOS persistence
  never uses this Codable path (GRDB records only; no CloudSync/ScoreUI usage — verified by search), so the marker's
  blast radius is the Android blob and tests.
- **`score_prefs` goes through `AnalyticsBridge` using the same Domain factory.** Matching the bridge's stateless
  builder pattern (`AnalyticsBridge.swift:7-22`): a `@WireletExpose` builder that takes one stored preferences JSON
  blob plus the width bucket input, decodes via `ReaderPreferencesReducer.decode`
  (`ReaderPreferencesReducer.swift:87-90`), and returns the encoded wire event — or an empty-named wire the Kotlin
  caller skips — so Kotlin's launch path simply enumerates its stored blobs and relays each one. Event name, presence
  rule, and every bucket boundary live in the shared factory; Kotlin authors no wire string (the invariant the bridge
  header documents, lines 12-15). Android passes its window width in dp as the width input — dp is Android's
  point-equivalent, and the analysis never compares widths across platforms without `platform`, which Firebase attaches
  automatically. A per-blob call (single `String` argument) deliberately avoids depending on wirelet's unreleased
  `[String]` method-arg support.

## 9. Testing

Swift Testing (`@Test`, `#expect`) throughout, per repo convention; package suites run via `xcodebuild test` with the
package scheme.

- **Domain** (`DomainTests`):
  - Optional round-trip through the memberwise `init` — `nil` in, `nil` out, for all four fields.
  - Clamping never materializes `nil` (e.g. `staffSize: nil` stays `nil`; `staffSize: 99` clamps to 28).
  - `effective*` resolution, including `effectiveStaffSize(default:)` following the injected default.
  - Codable: legacy blob (no `schemaVersion`) normalizes 14 / `true` / 1.0 / 0 → `nil` and keeps non-defaults; a v2
    blob with an explicit default value keeps it non-`nil`; encode → decode round-trips `nil` as `nil`.
  - `reconcilingAuthoredHidden`: fresh seed with empty authored set → `shouldPersist == false`; with authored staves →
    persists and records `authoredHiddenStaves`; the refresh rule updates a stale authored set without touching
    `hiddenStaves`.
  - `scorePrefs` factory: an all-untouched preferences value produces no event (or the emitting helper skips it);
    only non-`nil` fields appear as params; bucket boundaries (volume 300 → `master_volume_pct` 300; width 507 → 430;
    width 300 → 320); hid/reveal counts computed from the two sets.
- **Persistence** (`InfrastructureTests`, real SQLite): migrate fixture rows written at the v15 schema (via the new
  `upToV15` migrator) through v16 and assert the conversion table — `staff_size` 14 → NULL, 15 → 15; 
  `honor_layout_breaks` 1 → NULL, 0 → 0; `master_volume` 1.0 → NULL, 1.5 → 1.5; `transpose_semitones` 0 → NULL,
  −3 → −3; `authored_hidden_staves` equals the old `hidden_staff_ids`; `repeat_mode` untouched; PK + cascade still
  enforced. Record round-trip preserves `nil`.
- **Reader** (`ReaderTests`, fakes): **the §2 regression test** — set only a clef override through
  `LayoutSettingsModel`, drive the wired `onChange`, and assert the persisted `ReaderPreferences.staffSize` and
  `honorLayoutBreaks` are still `nil`. Same shape for hidden-staves-only changes. Stepper from untouched: first
  `incrementStaffSize` on a `nil` slice persists `default + 1`. `resetValue`/`reset` persist `nil`;
  `commitValue(1.0)` persists `.some(1.0)`. `loadOrSeed` with no stored row and no authored staves performs no
  repository save.
- **App/analytics emission** (Reader/App-level tests with a fake repository + recording analytics): an all-`nil` row
  emits no `score_prefs`; a row with one touched field emits exactly one event containing exactly that param plus
  `screen_width_pt`; trashed scores' rows are excluded.

## Known limitations

- **Changes made before this ships are invisible as history.** Every existing row enters the new world as "whatever
  v16 could infer": non-default stored values survive as changed (with their values), but any pre-v16 change that
  landed *on* a default value reads as untouched, and pre-v16 hides all read as authored until their score's next
  open. Early numbers therefore under-report (a) and (b); they converge as users open scores and change things
  post-update. There is no retroactive fix — the distinction was never recorded.
- **On Android, a pre-`schemaVersion` blob never reports `staff_size`.** The two platforms' migrations are not
  equivalent in outcome here, and only iOS's is exact. iOS seeded the frozen constant `14`, so v16's `CASE WHEN
  staff_size = 14 THEN NULL` separates seed from choice precisely. Android's since-removed eager seed wrote the
  *global* staff size in effect when the score was first opened — a prominent continuous 8…28 slider defaulting to its
  maximum — so a user who has since moved that slider leaves blobs matching no default in effect, and no rule keyed to
  the current global can tell a stale seed from a real choice. `AnalyticsBridge.scorePrefs` therefore drops
  `staff_size` for **every** legacy Android blob. Android's `staff_size` numbers consequently under-report until each
  score is next changed — the first mutation re-encodes it as `schemaVersion: 2`, after which the value is
  authoritative and reported. Under-reporting is the direction chosen everywhere else here (§4, §6). Rendering is
  unaffected: `ReaderPreferencesBridge.open` keeps the stored value, and the widening lives in the analytics builder
  alone.
- `score_prefs` reaches BigQuery only from launches on app versions carrying this change, and the BigQuery export
  itself is not retroactive; trend analysis starts at rollout.
- A score changed on one device and never opened where analytics consent differs follows the usual consent-gate
  semantics; no cross-device reconciliation is attempted.

## Out of scope (YAGNI)

- Sending any score identifier in `score_prefs`.
- Change history / "when did they change it" — `score_prefs` is a state snapshot; per-change events for these controls
  can be added later if a funnel question ever materializes.
- Actually choosing the iPad staff-size default (this lays the groundwork; `ReaderRootScreen.swift:166` stays a
  constant until that follow-up).
- Registering GA4 custom dimensions for the new params (BigQuery captures them regardless).
- Dropping the legacy `repeat_mode` column or the Domain `repeatMode` field (kept as-is; a future cleanup).
- An `ab_repeat`-presence parameter (loop usage is already observable via `repeat_mode_changed`).
- Android UI changes of any kind (Compose reads the same resolved projection as today).
