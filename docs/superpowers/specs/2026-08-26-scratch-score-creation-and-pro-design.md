# Scratch Score Creation & folino Pro — Umbrella Design

**Date:** 2026-08-26
**Status:** Approved direction; per-milestone specs/plans to follow
**Scope:** Product + monetization decisions and milestone decomposition for creating scores from scratch, and the folino Pro subscription that gates it.

This is an umbrella spec: it records the decisions that frame the work. Each milestone below gets its own implementation plan (and, where the design is non-trivial, its own spec) before code is written.

## 1. Product decision

folino gains the ability to **create a score from scratch** — not just read, play, and edit imported scores. The release bar is deliberately high: we do not ship until a user can honestly be told "you can write sheet music in folino."

**Release bar (all required before the feature ships):**

1. **Creation wizard** — template picker (SATB, string quartet, piano, combo, …) plus a free instrument list; title/composer metadata; key signature, time signature, tempo, anacrusis (pickup measure), initial measure count.
2. **Ensemble support** — multiple parts, including **transposing instruments** (B♭ trumpet/clarinet etc. written at transposed pitch). Instrument catalog of ~20–30 GM-soundfont-playable instruments (voices, piano, strings, woodwinds, brass, guitar/bass, drum kit), each carrying transposition, default clef(s), and range metadata — a reduced instruments.xml equivalent.
3. **Measure operations** — append, insert, delete.
4. **Part operations after creation** — add and remove parts on an existing score.
5. **Key/time signature changes** — set at creation, **changeable after the fact**, and **changeable mid-piece** (time change re-bars the affected region; key change re-spells). Without this we cannot claim score creation.
6. **Rehearsal mark editing** — create, rename, delete. Rehearsal-mark seek is a folino identity feature; created scores must be able to carry them.
7. **Drum note entry** — separate work stream (spec `2026-08-12-drum-note-entry-design.md`), but ships in the **same release**. The creation wizard includes drum kit as an instrument; the entry UI comes from that stream.

**Non-goals for this release:** lyrics-focused tooling beyond what editing already has, chord symbols, repeats/voltas authoring, dynamics/articulation authoring. These are post-release extensions; the existing editor's note-level capabilities define the writing surface at launch.

**Reference implementation: MuseScore.** UX (New Score wizard flow), the instrument catalog shape, and the re-barring behavior on time-signature change follow MuseScore's precedent. The local source clone (`~/Developer/musescore/MuseScore`) is the reference. **Behavioral/UX reference only — MuseScore is GPL and no code may be ported or translated from it** (repo hard constraint: no GPL dependencies). Algorithms are implemented clean-room in ssm.

## 2. Monetization decision

### Shape: one entitlement, subscription only

A single **folino Pro** entitlement, sold as an **auto-renewing subscription — monthly and annual only**. No lifetime/non-consumable tier. Rationale: the launch value (creation) is deliberately thin, and value grows over time as cloud sync & group collaboration fold into the *same* entitlement — a subscription lets the price stay constant while the bundle deepens. One paywall, one `isPro`, one mental model.

| Free | folino Pro (subscription) |
| --- | --- |
| Read, play, import — unlimited | Unlimited scratch creation |
| Edit any existing score — unlimited | (later) create/host shared groups |
| Scratch-create up to the free quota (**3 scores**) | (later) full cloud-sync quota |
| (later) join shared groups, small sync quota | |

Working price points: ¥400/month, ¥3,000/year (final numbers set at App Store Connect configuration; the monthly:annual ratio ~10× monthly per year is the intent).

### Rules

- **No data hostage.** Scores created under Pro (or under the free quota) remain fully viewable **and editable** after churn. Lapsing Pro only removes forward-looking abilities: creating *new* scratch scores beyond quota, and (later) group hosting / extra sync quota.
- **Quota counts scratch-created scores** (scores whose origin is the creation wizard), not edits, not imports. Import stays free and ungated — the known workaround (importing a blank MusicXML) is accepted; we do not degrade the import feature to close it.
- **Cloud folds in later, and collab never ships free.** The group sharing/collab work (worktree `worktree-group-sharing-collab`, Firebase-backed, currently unverified) releases only *together with* its Pro gating: join/view is free (share links are the acquisition channel — the host pays), group creation/hosting requires Pro, personal sync keeps a small free quota with Pro raising it. Shipping collab free first and charging later is explicitly forbidden by this spec.
- **App Store fit.** At launch the subscription's ongoing value is the creation capability plus continued development; once cloud joins, the recurring-cost service makes the subscription's "ongoing value" case unambiguous.

### Infrastructure

The IAP layer is **extracted from VocalTuner into a shared package** (same playbook as swift-screenshot-kit): `EntitlementStore`, paywall UI, quota surfaces, and the SKTestSession-based test harness, extended with auto-renewing-subscription status tracking (VocalTuner today is non-consumable-only). VocalTuner migrates to the shared package as a follow-up on its own schedule; folino is the first consumer. Package naming and API surface are M5's design work.

In folino's architecture the entitlement check is a Domain protocol; the StoreKit adapter lives in Infrastructure; Features (Library's creation entry point, later Sharing) consume the protocol via constructor injection, per the module rules.

## 3. Engineering shape

The dominant work is in **swift-sheet-music** (ssm): the entire `EditCommand` surface today is note-level (`InputNote`, chords, tuplets, ties, accidentals, lyrics). Nothing exists for document creation, measure operations, part operations, or signature changes. New ssm capability, in ascending weight:

1. **Score factory** — build an empty `Score` (parts, staves, clefs, signatures, N rest-filled measures). Serialization needs nothing new: creation saves through the existing `LiveScoreFileGateway.saveScore` mscx/mscz engine encoders.
2. **Measure commands** — append/insert/delete across all parts; undo via the existing composite-command machinery.
3. **Part commands** — add/remove a part on an existing score: staff insertion into every measure, `StaffAddress`/positional-ID re-stamping (the write-path sibling of the `filtered(hidingStaves:)` re-stamping already proven on the display path), bracket/system layout updates.
4. **Signature commands** — mid-piece and global key/time changes. Time-signature change **re-bars** the affected region (redistribute voice elements across new measure boundaries, splitting/tying notes at barlines); key change re-spells via the existing `MeasureAccidentals` state machinery. This is the heaviest single item; MuseScore's behavior is the reference for edge cases (tuplets crossing new barlines, pickup interaction, courtesy signatures).
5. **Rehearsal mark command** — set/rename/remove on a measure; model, rendering, and seek-unwind already exist.

ssm changes follow the one-way street: local pin → verify in folino → ssm release → re-pin. Folino-side work (wizard UI, Library entry point, paywall) rides Feature packages per the module architecture (creation entry likely in Library; part/signature editing surfaces in the existing Editor chrome).

Android parity: per repo policy, logic lands shared (ssm + Domain); the Android wizard/UI follows iOS release by its own schedule with `PARITY(android)` markers at divergence points.

## 4. Milestones

| # | Content | Depends on |
| --- | --- | --- |
| M1 | **Solo/piano creation (path A)** — Score factory, minimal wizard (single instrument or grand staff), measure append/insert/delete. Proves the full loop: create → edit with existing pad → save → read. | — |
| M2 | **Ensemble** — instrument catalog (incl. transposition metadata), templates, multi-part wizard, part add/remove post-creation. | M1 |
| M3 | **Signatures** — after-the-fact and mid-piece key/time changes (re-barring, re-spelling). | M2 (written once against the post-part-editing score shape) |
| M4 | **Rehearsal marks** — create/rename/delete in the editor. | M1 |
| M5 | **folino Pro IAP** — shared package extraction from VocalTuner, subscription support, paywall + quota UI in folino. | independent; parallel to M1–M4 |
| M6 | **Drum note entry** — separate stream, existing spec. | independent |

Release = M1–M6 all landed. M1 is usable internally (TestFlight) from the moment it lands; nothing ships to the App Store before the full bar is met. Sequencing rationale: M3 after M2 so re-barring is written once against the final score shape; M4 anytime after M1; M5/M6 fully parallel.

Each milestone starts with its own spec (where design is non-trivial: M2, M3, M5) or directly with an implementation plan (M1, M4).

## 5. Risks & open questions

- **Re-barring complexity (M3)** is the schedule risk. Mitigation: MuseScore behavioral reference, and a corpus-style round-trip test bed in ssm (create → change signature → export → re-import → compare) before UI work.
- **Free quota number** is set at 3; revisit at paywall design time with no structural impact.
- **Exact prices** and subscription-group configuration are decided at App Store Connect setup during M5.
- **Collab verification** (`worktree-group-sharing-collab`) is untested and out of scope here; only its *monetization coupling* (never ships free; joins the Pro entitlement) is fixed by this spec.
