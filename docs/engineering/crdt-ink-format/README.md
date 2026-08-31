# Apple's `crdt` ink container — reverse-engineering notes

Research branch. **Nothing here ships**; the goal is to learn whether folino can write the payload Apple's own
markup recognizes, so that ink exported by folino can be erased with the PencilKit eraser in Files, Books and
Preview on any device.

Split out of `worktree-annotated-pdf-export` so the export feature — which is finished and works without any of
this — is not held up by an open-ended investigation.

## What is already established

Every line below was measured, not inferred. The tools that produced each measurement are in `tools/`.

### Apple stores ink twice

A Books-exported PDF carries, per page, exactly one annotation:

- `/Stamp` for Pencil ink, with `/AAPL:AKExtras` → a dictionary holding
  - `/PPK` — base64 of a container whose first four bytes are `63 72 64 74` = `crdt`
  - `/PPKType` — base64 of exactly three bytes, `76 b6 b0`, identical across every sample seen
- `/Square` for shape markup, with `/AAPL:AKAnnotationV2` — an `NSKeyedArchiver` plist
- `/F = 644` (Print + Locked + LockedContents), `/T = "Mobile User"`
- an `/AP` appearance stream containing **zero vector path operators** — just `Do` against an image XObject

So the visible ink is a raster, and the editable truth is the private blob. Rendering a page's content stream
versus rendering it through PDFKit differs by tens of thousands of pixels, confirming the ink is not flattened
into the page body.

### The container is the gate

A controlled swap settled this. Taking Books' own PDF and replacing **only** the `/PPK` value — Apple's `crdt`
blob for a folino-produced one, leaving subtype, flags, `/PPKType`, the raster `/AP` and the page content
untouched — stopped the Files.app eraser from working on it.

Reproducing every other field exactly (subtype `/Stamp`, the nested `/AAPL:AKExtras` dictionary, `/PPKType`
byte-identical, `/F = 644`, one annotation per page) did **not** make the eraser work while the container
differed.

### folino cannot produce `crdt` through public API

`PKDrawing.dataRepresentation()` emits a `wrd`-prefixed container (`77 72 64 f0 01 00 08 00`), measured for an
empty drawing, a drawing built from control points, and across ink types and content versions.

And `crdt` is not something PencilKit can read either: `PKDrawing(data:)` refuses Apple's blob with
`NSCocoaErrorDomain Code=3` ("Apple描画フォーマットデータが正しくありません"). So `crdt` is AnnotationKit's own
container, not a PencilKit serialization.

`AnnotationKit` is a **private** framework: `/System/Library/PrivateFrameworks/AnnotationKit.framework` exists,
has no headers, and is absent from the iOS SDK. Linking it is not an option for an App Store app.

### The payload is protobuf, and it is legible

From offset 8 (after `crdt` + a four-byte header `06 00 03 00`) the payload parses cleanly as protobuf — 25+
consecutive fields with no length overrun, which does not happen by chance.

Shape of Books' page-1 blob (33,680 bytes, roughly 26 strokes of ink):

```
.3                       n=1     21 bytes      small metadata
.4.3                     n=106   1908 bytes
.4.4.1                   n=27    729 bytes
.4.4.10.1.2.7            n=26    15932 bytes   the bulk — about 612 bytes each
.4.4.10.1.2.2  fixed64   n=26
.4.4.10.1.2.3  varint    n=26
```

The recurring 26 / 27 counts track the number of strokes, and `.4.4.10.1.2.7` is almost certainly the point
data. Readable strings in the blob — `strokes`, `canvasBounds`, `transform`, `inherited`, `properties`,
`com.apple.ink.pen`, `fixed-width` — are PencilKit's own vocabulary.

`crdt` most likely stands for Conflict-free Replicated Data Type: a structure built so independent edits on
several devices merge deterministically. That would explain both the size (per-element identifiers and causal
metadata, not just geometry) and why partial erase survives syncing between devices. **This is inference from
the name and the structure — Apple has published nothing.**

### Nobody has done this publicly

Searched. No documentation of `crdt`, `/PPK` or `AAPL:AKExtras` byte layout exists. `pdfcpu` issue #955 reports
`AAPL:AKExtras` only as a validation failure, with no analysis.

The closest prior art, `chrisns/apple-notes-to-obsidian`, hit the same wall extracting Apple Notes handwriting
and **chose not to** reverse-engineer it: *"faithfully decoding it would be days of work and would break on the
next macOS update."* They shimmed the private framework instead — viable for a local Mac utility, not for an
App Store app. Note that synthesizing the bytes ourselves is a different matter: it uses no private API and is
App Store compatible, which is why this line of work is worth pursuing at all.

## Method from here

Differential analysis. `tools/makesamples.swift` generates an 8-page PDF with one controlled mark per page, so
blobs differing by exactly one drawing variable can be compared field path by field path:

| page | mark | isolates |
| --- | --- | --- |
| 1 | thin black line | baseline |
| 2 | identical to page 1 | what changes between two identical drawings — identifiers, timestamps |
| 3 | same line, red | the colour field |
| 4 | same line, thickest | the width field |
| 5 | two separate lines | how stroke count is represented |
| 6 | one vertical line | coordinate ordering |
| 7 | a single dot | the minimum structure |
| 8 | a long slow wave | how point count scales the payload |

`tools/pbdump.py --summary` gives a diffable field-path listing; without `--summary` it prints the full tree.

The likely hard part is not geometry but the identifiers: whether the values in `.3`, `.4.4.1` and the header
are inert version markers (which can be copied) or device identifiers and logical clocks that AnnotationKit
validates (which cannot be synthesized). Nothing decides that except trying it on a device.

## Tools

| file | what it does |
| --- | --- |
| `tools/pbdump.py` | recursive protobuf structure dumper; `--summary` for diffing |
| `tools/dumpppk.swift` | extracts every `/PPK` / `/AAPL:AKExtras` blob from a PDF to disk |
| `tools/analyzebooks.swift` | annotation inventory: subtypes, keys, and a body-vs-annotation render diff |
| `tools/apstream.swift` | reports whether an `/AP` appearance stream is vector or a raster |
| `tools/flags.swift` | prints `/F` flag bits, `/T` and `/Name` per annotation |
| `tools/swapppk.swift` | the controlled experiment: swap one `/PPK` into another document |
| `tools/makesamples.swift` | generates the sample-collection PDF |

Run the Swift ones with `xcrun swift <file> <args>`. PencilKit cannot run in a macOS command-line tool
(SIGTRAP), so anything touching `PKDrawing` has to be a test in the app's hosted `FolinoTests` target.

Extract blobs into a **dedicated empty directory** — the extractor names files by page and index, so pointing
two different PDFs at one directory silently overwrites fixtures. That mistake already invalidated one
measurement here.

---

# BREAKTHROUGH (2026-09-01): the editable format is NOT `crdt`

Everything above about `crdt` remains true, and is now largely beside the point.

## The eraser works on `AKAnnotationV2`, and that format is tractable

Apple Books writes ink two different ways. The `ギブス.pdf` sample had `/Stamp` + `/PPK` (`crdt`) on pages 1-3
and `/Square` + `/AAPL:AKAnnotationV2` on pages 4-9. A fresh 8-page sample annotated in Books today came back
**entirely** as `AKAnnotationV2` — suggesting `crdt` is the older path and `AKAnnotationV2` the current one.

**Measured on device: the eraser works on the `AKAnnotationV2` file.** So this — not `crdt` — is the format to
target, and every part of its envelope is public:

```
/Square annotation, /AAPL:AKExtras → /AAPL:AKAnnotationV2
  └ NSKeyedArchiver                       (public API)
    └ AKInkAnnotation2 { drawing, rect{X,Y,W,H}, originalModelBaseScaleFactor, UUID, … }
      └ gzip                              (trivial)
        └ protobuf, no magic header       (schema below)
```

## Decoded schema

Field paths are as `tools/pbdump.py --offset 0` prints them.

| path | type | meaning | evidence |
| --- | --- | --- | --- |
| `.2.3.2` | 16 bytes | UUID | differs between two identical drawings |
| `.2.3.4.1` | fixed32 ×4 | **RGBA**, 0…1 floats | black = `0,0,0,1`; red = `0.9882,0.1922,0.2588,1` = `FC3142` |
| `.2.3.4.2` | string | tool id, `com.apple.ink.pen` | constant across samples |
| `.2.3.4.3` | varint | 3 | constant |
| `.2.3.5.4` | varint | **point count** | 95 and 92 for two samples |
| `.2.3.5.5` | bytes | **points, 24 bytes each** | length is exactly count × 24, both times |
| `.2.3.5.6` | fixed32 ×4 | bounding box x, y, w, h | matches the点 coordinates |
| `.2.3.5.11` | fixed64 | creation timestamp (CFAbsoluteTime double, ≈7.9e8 → 2026) | high bytes shared, low bytes differ |
| `.2.3.5.13`, `.2.3.5.14`, `.2.3.9` | 16 bytes each | UUIDs | differ between identical drawings |
| `.2.3.10` | message | `{0, 1, 0}` | constant |

### The 24-byte point record

```
[0:4]   float32  time offset      0.0, 0.004, 0.033 … increasing
[4:8]   float32  x                page-space
[8:12]  float32  y                page-space
[12:14] uint16   width            26 = thin pen, 40 = thickest   ← isolated by the width sample
[14:16] uint16   1000             constant
[16:18] uint16   0                constant
[18:20] uint16   force            varies per point
[20:22] uint16   0xAAAA           constant (azimuth?)
[22:24] uint16   0xFE54           constant (altitude?)
```

Maps one-to-one onto `PKStrokePoint` (location, timeOffset, size, opacity, force, azimuth, altitude), which is
what folino already stores per point in `InkStroke`.

## Why this is synthesizable

The only per-drawing values that are not geometry are **UUIDs and a timestamp**. Nothing resembles a device
identity, a logical clock, or a signature — nothing that AnnotationKit could validate against state we do not
have. Generating fresh UUIDs and a current timestamp should be legitimate.

**No history is retained.** One sample was drawn with the wrong pen, undone, and redrawn; its payload is about
twice a single stroke, not three times, so the undone stroke left no tombstone. Whatever CRDT machinery the
`crdt` container implies, this format stores the current state only.

## Remaining unknowns

- `.2.1`, `.2.2`, `.2.3.1` (all = 10) and the `.2.3.3` triples `{1,0,1}` / `{0,1,0}` — presumably versions and
  small flags; safe to copy verbatim until proven otherwise.
- The coordinate space: values sit around 330-450 for marks drawn near the page centre, while the page is
  595×842. `originalModelBaseScaleFactor` (0.7997) and the archived canvas size (792.77 × 1122.06) are the
  likely conversion, but this has not been derived yet.
- Whether a synthesized archive is accepted. Nothing settles that except writing one and erasing it on a device.

## Next step

Round-trip first, synthesize second: decode a real sample, re-encode it with our own writer, put it back in a
PDF, and confirm the eraser still works. Only then start changing geometry. That separates "our writer is
faithful" from "our geometry is right", which are different failures.
