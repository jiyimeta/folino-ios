# Folino — Product Docs

Folino is a score viewer / player / light annotator for performing musicians, built native to iPad and iPhone (iOS 26+).

These documents describe **what** Folino is and **why**. Implementation-level decisions live in [`../engineering/`](../engineering/) and in per-feature plans created when each piece of work begins.

| Document | Purpose |
| --- | --- |
| [vision.md](./vision.md) | Positioning, design principles, target users. |
| [features.md](./features.md) | Functional spec, with the v1 / future cut line called out per area. |
| [architecture.md](./architecture.md) | Information architecture, high-level data model, permissions. |
| [feasibility.md](./feasibility.md) | Technical risks, decided trade-offs, items still to validate. |
| [roadmap.md](./roadmap.md) | Phasing from v1 to v3+. |
| [privacy-and-accessibility.md](./privacy-and-accessibility.md) | Data handling, network use, a11y commitments. |

The companion engineering doc:

- [`../engineering/module-architecture.md`](../engineering/module-architecture.md) — SPM module layering rules and DI conventions.

## Engine Dependency

Folino is the application layer. The notation, layout, audio, and file-format work lives in [`swift-sheet-music`](https://github.com/jiyimeta/swift-sheet-music). When Folino needs an engine capability that does not yet exist there, the rule of thumb is:

- Generic to any score app → upstream PR to `swift-sheet-music`.
- Specific to Folino's UX, library, or sync → inside Folino's own packages.

That boundary is restated in `feasibility.md` and `module-architecture.md`.
