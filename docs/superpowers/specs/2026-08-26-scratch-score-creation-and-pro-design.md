# Scratch Score Creation & folino Pro — Umbrella Design

**Date:** 2026-08-26
**Status:** Approved direction; per-milestone specs/plans to follow. Revised 2026-08-28: monetization pivot — creation is free on all platforms; Pro sells cloud services (§2).
**Scope:** Product + monetization decisions and milestone decomposition for creating scores from scratch, and the folino Pro subscription (which does not gate creation — see §2).

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

> Revised 2026-08-28. The original decision gated scratch creation behind a free quota of 3 scores. With a macOS version planned on a ~1-month horizon (and Windows eventually), that gate is rescinded: see "Creation is free" below. The entitlement shape and the collab coupling survive unchanged.

### Creation is free — unlimited, on every platform

Scratch creation ships **free and unlimited on iOS, iPadOS, macOS, Android, and any future platform (Windows)**. No quota, no mobile-only limit. Rationale:

- **Category expectation.** MuseScore Studio makes desktop notation free; a folino desktop app must match that to compete, and once it does, a mobile-only creation gate is an indefensible asymmetry ("free on your Mac, paid on your iPhone — for the same file").
- **Sync makes a per-device quota incoherent.** The moment cloud sync lands, "create on desktop, open on phone" is one tap; the mobile gate would be a bypassable fiction that collects resentment, not revenue.
- **MuseScore's mobile paywall is the opening.** Muse Group's mobile app monetization is the most-hated part of their product. "folino doesn't nickel-and-dime creation on mobile" is the cheapest differentiation we can buy, and it targets exactly the users we want to win.
- **The industry pay line is cloud, not the tool.** Muse Group's own revenue is musescore.com Pro; Flat/Noteflight gate *cloud-stored* score counts. folino scores are local files — gating local creation reads like charging per document.

### Shape: one entitlement, subscription only

A single **folino Pro** entitlement, sold as an **auto-renewing subscription — monthly and annual only**. No lifetime/non-consumable tier. Pro sells the services with recurring cost: cloud sync and group collaboration, plus future compute-backed features. One paywall, one `isPro`, one mental model.

| Free | folino Pro (subscription) |
| --- | --- |
| Read, play, import, edit — unlimited | Full cloud-sync quota |
| **Scratch-create — unlimited, all platforms** | Create/host shared groups |
| Join shared groups; small personal sync quota | (future) compute-backed features, e.g. PDF→score conversion |

Working price points (placeholders only — **deliberately undecided**): ¥400/month, ¥3,000/year. Final numbers and the monthly:annual ratio are set at App Store Connect configuration when Pro launches with cloud/collab.

**Pro launches together with cloud/collab — not with the creation release.** The creation feature ships fully free with no paywall surface. Zero revenue until the cloud release is accepted (decided 2026-08-28).

### One plan, every platform

A Pro subscription bought on any platform is valid on all of them:

- **iOS/iPadOS ⇄ macOS:** universal purchase (same bundle ID, Mac App Store). StoreKit shares the subscription automatically; no server involved.
- **⇄ Android, Windows, web:** account-linked entitlement — store receipts (StoreKit / Play Billing) are validated server-side (Firebase) and recorded on the user's account; clients read the account entitlement. The account infrastructure from the sharing stream (SP1) is the identity layer. Long-term the account entitlement is the source of truth; a direct StoreKit check remains the offline/no-account bootstrap path on Apple platforms.

### Rules

- **Creation is never gated.** No future revision may put a quota, watermark, or export limit on scratch creation. The pay line stays at services (sync, collab, server compute).
- **No data hostage.** Everything a user created remains fully viewable and editable after churn. Lapsing Pro only removes forward-looking service abilities: group hosting and the extra sync quota.
- **Collab never ships free.** The group sharing/collab work (worktree `worktree-group-sharing-collab`, Firebase-backed, currently unverified) releases only *together with* its Pro gating: join/view is free (share links are the acquisition channel — the host pays), group creation/hosting requires Pro, personal sync keeps a small free quota with Pro raising it. Shipping collab free first and charging later is explicitly forbidden by this spec.
- **App Store fit.** Pro sells a recurring-cost service (sync/collab/compute), the cleanest possible "ongoing value" case for an auto-renewing subscription.

### Infrastructure (deferred — no longer part of this release)

The IAP layer will be extracted from VocalTuner into a shared package (same playbook as swift-screenshot-kit): `EntitlementStore`, paywall UI, and the SKTestSession-based test harness, extended with auto-renewing-subscription status tracking. **This extraction was M5 and is dropped from this release entirely (2026-08-28) — it is future work that rides with the Pro/cloud-collab launch.** When it eventually lands in folino, the entitlement check is a Domain protocol, the StoreKit adapter lives in Infrastructure, and Features consume the protocol via constructor injection, per the module rules.

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
| M5 | **folino Pro IAP — dropped from this release (2026-08-28).** Shared-package extraction, subscription support, and paywall are future work tied to the Pro/cloud-collab launch. Row number retained so M6 references stay stable. | — |
| M6 | **Drum note entry** — separate stream, existing spec. | independent |

Release = M1–M4 + M6 all landed (M5 dropped 2026-08-28 — Pro/IAP is future work tied to the cloud/collab launch). M1 is usable internally (TestFlight) from the moment it lands; nothing ships to the App Store before the full bar is met. Sequencing rationale: M3 after M2 so re-barring is written once against the final score shape; M4 anytime after M1; M6 fully parallel.

Each milestone starts with its own spec (where design is non-trivial: M2, M3) or directly with an implementation plan (M1, M4).

## 5. Risks & open questions

- **Re-barring complexity (M3)** is the schedule risk. Mitigation: MuseScore behavioral reference, and a corpus-style round-trip test bed in ssm (create → change signature → export → re-import → compare) before UI work.
- **Prices are deliberately undecided.** The ¥400/¥3,000 figures in §2 are placeholders; final numbers and the monthly:annual ratio are set at App Store Connect configuration when Pro launches with cloud/collab.
- **Cross-store entitlement backend** (receipt validation, account-linked entitlement for Android/Windows) is designed in the account/sharing stream, not here; this spec fixes only the product rule that one subscription is valid on every platform.
- **Collab verification** (`worktree-group-sharing-collab`) is untested and out of scope here; only its *monetization coupling* (never ships free; joins the Pro entitlement) is fixed by this spec.
