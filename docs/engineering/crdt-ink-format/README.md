# Apple's `crdt` ink container — reverse-engineering notes

Research branch. **Nothing here ships**; the goal is to learn whether folino can write the payload Apple's own
markup recognizes, so that ink exported by folino can be erased with the PencilKit eraser in Files and Books
on any device. (For macOS Preview specifically, see "What AKAnnotationV2 costs" below.)

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

---

# Round trip verified without a device (2026-09-01)

`tools/pbcodec.py selfcheck` parses Apple's payload and writes it back. On four samples of different sizes
(303, 2512, 4599, 7145 bytes) the result is **byte-identical** to the input. So the read/write path is faithful,
and any later difference on device is attributable to what we changed rather than to how we rewrote it.

`tools/pbcodec.py points` confirms the stroke model end to end: the two-line sample separates into exactly two
strokes of 93 and 80 points, each payload exactly 24 × count bytes, at the two y positions the marks were drawn
at, both at `width = 26` — and with no third stroke, confirming again that the undone thick line left nothing.

## Coordinate spaces

Points live in a **canvas space** (792.77 × 1122.06 for an A4 page); the archive's `X/Y/Width/Height` rect is in
**page space** (595 × 842, y up). The conversion is `page = canvas × 0.7504` with the y axis flipped about the
page height. Checked against the single-dot sample: canvas (335.2, 450.6) → x 251.6 against a stored `X` of
249.93, and `842 − 450.6 × 0.7504 = 503.8` against a stored bottom edge of `502.07 + 1.5`.

`originalModelBaseScaleFactor` in the archive is 0.799731, which is **not** that ratio; its meaning is still
unknown, and it is left untouched.

## The three-variant test

`tools/mkvariants.py` builds three archives from one real sample, and `tools/applyvariants.swift` writes them
into a copy of the source PDF — one per page, leaving the other pages untouched so they act as a control in the
same document and the same viewing session.

| variant | what it changes | what a failure means |
| --- | --- | --- |
| A round-trip | nothing; parsed and re-serialized | our read/write path damages the payload |
| B translated | every point moved in x, and the archive rect moved to match | geometry may not be rewritten |
| C synthesized | our own 48-point zigzag, fresh UUIDs and timestamp, undecoded scaffolding copied | one of the values we generate is validated |

**The variants deliberately do not touch `/AP`.** The visible ink therefore still shows the original mark until
something re-renders it. That is a feature of the test: if Apple's markup adopts the payload, opening the file
for editing should move the ink to the payload's position, which is a clearer signal than the eraser alone.

Variant C is the shape production code would emit: everything understood is regenerated, and only fields still
undecoded are copied as constants.

---

# Device bisect results (2026-09-01)

Five rounds, each written back into a copy of the user's own Books-annotated PDF with untouched pages left in
as controls. Three of the five rounds were invalidated by test-design errors on my side; those are recorded
because the corrections are what produced the rule.

## What is free to change

Each of these was changed alone, written back to the page it came from, and **accepted** — the mark still
erased and selected in Files:

| field | path |
| --- | --- |
| point coordinates | `.2.3.5.5` |
| the stored bounding box | `.2.3.5.6` |
| the timestamp | `.2.3.5.11` |
| the stroke's UUIDs | `.2.3.5.13`, `.2.3.5.14` |
| the stroke container's UUIDs | `.2.3.2`, `.2.3.9` |
| the point count | `.2.3.5.4` |

So nothing inside the drawing payload is validated against anything we cannot generate. Fresh UUIDs and a
current timestamp are fine.

## The one rule

Changing the archive's `rectangle` alone is rejected. Changing the annotation's `/Rect` alone is rejected.
Rejection is total — the mark can neither be erased nor selected, so the payload is being discarded at load.

**The stored bbox, the archive `rectangle` and the annotation `/Rect` must all describe the same box.**

The mapping, verified against all eight samples to within 0.12pt:

```
sx, sy = pageW / drawingSize.Width, pageH / drawingSize.Height
X = bbox.x * sx
Y = pageH - (bbox.y + bbox.h) * sy
W = bbox.w * sx
H = bbox.h * sy
```

`drawingSize` is the archived canvas size (792.77 x 1122.06 for A4); point coordinates live in that canvas
space, the rectangles in page space with y up.

## Errors in my own test design, and what they cost

Worth recording, because each one produced a confident wrong reading before it was caught:

1. **Round 1** changed geometry *and* regenerated the timestamp and two UUIDs in the same variant, so it
   isolated nothing.
2. **Round 2** derived every variant from page 1's archive but wrote them onto pages 1-6. Each PDF annotation
   keeps its own `/Rect`, so pages 2-6 disagreed with their own annotation before any intended edit mattered —
   and page 1, the only page whose `/Rect` matched, was the only one accepted. This briefly looked like proof
   that timestamps and UUIDs are validated. They are not.
3. **Round 3** moved the ink and set both rectangles, but computed the rect from the *point coordinates*
   instead of the stored bbox field. That loses the padding Apple keeps around the stroke — roughly half the
   pen width, so it grows with thickness — putting the rect 0.7 to 5pt out and, again, mismatched.

The lesson each time was the same: one variable per variant, and verify from the artifact that only that
variable moved.

---

# Solved (2026-09-01)

## The drawing payload can be synthesized

Round six replaced a 95-point stroke with 40 points of our own geometry, kept the stored bbox byte-identical
and touched no rectangle anywhere. **Accepted on device** — it erases and selects like Apple's own ink. Every
field inside the payload has now been changed successfully at least once: points, bbox, timestamp, all four
UUIDs, and the point count.

Round six also cleared the tooling of suspicion: re-setting `/Rect` to its own current value, and rewriting the
archive rectangle with its own current values, were both accepted. PDFKit's setter and plist round-tripping are
not the problem.

## The rectangle must match exactly

So the earlier rejections really were about the rectangle's value — and the reason the "consistent" attempt in
round five still failed is embarrassing and simple: the formula used **A4's nominal 595.2756 x 841.8898** while
the sample PDF's MediaBox is exactly **595 x 842**. That is a discrepancy of about 0.1pt, and it is enough for
the annotation to be discarded.

With the page's real MediaBox the mapping is exact — zero error, to the last decimal, on all eight samples:

```
sx, sy = pageW / drawingSize.Width, pageH / drawingSize.Height
X = bbox.x * sx
Y = pageH - (bbox.y + bbox.h) * sy
W = bbox.w * sx
H = bbox.h * sy
```

And the annotation's `/Rect` is **not** the archive rectangle. It is that rectangle grown by exactly one point
on every side — measured at `-1.0 / -1.0 / +2.0 / +2.0` on all eight samples, to four decimals:

```
/Rect = (X - 1, Y - 1, W + 2, H + 2)
```

Setting `/Rect` equal to the archive rectangle, which is what it looks like it should be, puts every edge 1pt
out and the annotation is discarded. An earlier round passed only because it re-set `/Rect` to the value it
already had, which happened to be correct.

Three consequences for any implementation:

- use the page's actual MediaBox, never a nominal paper size
- do not round the value on its way to `/Rect`; 0.1pt is already too much
- grow `/Rect` by 1pt on each side relative to the archive rectangle

## What this means for folino

Everything needed is now known and reachable with public API only:

| piece | how |
| --- | --- |
| envelope | `NSKeyedArchiver` of `AKInkAnnotation2`, gzip, header-less protobuf |
| geometry | 24-byte point records, canvas space |
| colour, width, tool | decoded fields, per stroke |
| identity | fresh UUIDs and a current timestamp are accepted |
| placement | stored bbox = archive rectangle = `/Rect`, by the exact mapping above |

folino creates its own annotations rather than editing Apple's, so it controls all three rectangles from the
start — the one hard constraint is the easiest one for it to satisfy.

---

# Confirmed end to end (2026-09-01)

Ink moved to a new position, ink synthesized in place, and ink synthesized at a different position on the page
were **all accepted on device** — each erases and selects in Files exactly like Apple's own markup.

> **This section overstated the result when it was written, and the next round proved it.** Every variant above
> synthesized *geometry* inside scaffolding copied from the very sample it was written back into. That shows the
> geometry is free; it does not show an encoder can emit the format, because the fields whose meaning is still
> unknown had never once been supplied by us. Modifying a structure can succeed on parts of it you do not
> understand. Only synthesis tests whether you know the rules — see **Built, not edited** below, which is where
> the format actually got solved, and which found two defects in our writer that this round could not have.

## The complete recipe

```
PDF annotation, subtype /Square
  /Rect              = archiveRect grown 1pt on every side
  /AAPL:AKExtras     = dictionary
     /AAPL:AKAnnotationV2 = base64 of
        NSKeyedArchiver archive of AKInkAnnotation2
           rectangle        = archiveRect            (page space, y up)
           drawingSize      = the canvas size        (e.g. 792.77 x 1122.06 for A4)
           UUID, akPlat=2, akVers=2, originalModelBaseScaleFactor, and the other scalars
           drawing          = gzip of
              protobuf, no magic header:
                .2.3.4.1   RGBA, four float32 in 0...1
                .2.3.4.2   tool id, e.g. "com.apple.ink.pen"
                .2.3.5.4   point count
                .2.3.5.5   count x 24-byte records:
                             [0:4]   float32 time offset, increasing
                             [4:8]   float32 x   (canvas space)
                             [8:12]  float32 y   (canvas space)
                             [12:14] uint16 width      26 = thin pen, 40 = thickest
                             [14:16] uint16 1000       constant
                             [16:18] uint16 0          constant
                             [18:20] uint16 force      per point
                             [20:22] uint16 0xAAAA     constant
                             [22:24] uint16 0xFE54     constant
                .2.3.5.6   bbox: four float32, x y w h, canvas space, WITH the pen's padding
                .2.3.5.11  fixed64 CFAbsoluteTime
                .2.3.2 .2.3.9 .2.3.5.13 .2.3.5.14   UUIDs, freshly generated is fine
                everything else copied verbatim from a real sample
```

with

```
sx, sy      = pageW / drawingSize.Width, pageH / drawingSize.Height   (pageW/H = the real MediaBox)
archiveRect = (bbox.x * sx,  pageH - (bbox.y + bbox.h) * sy,  bbox.w * sx,  bbox.h * sy)
/Rect       = (archiveRect.x - 1, archiveRect.y - 1, archiveRect.w + 2, archiveRect.h + 2)
```

The three boxes must agree to well under 0.1pt or the annotation is discarded silently — it neither erases nor
selects, and only the `/AP` keeps it visible.

## Still unknown, and not blocking

- `.2.1`, `.2.2`, `.2.3.1` (all 10), the `.2.3.3` triples, `.2.3.5.1/.2/.3/.9`, `.2.3.10` — copied verbatim
  from a sample and never varied. Worth probing before shipping, in case one of them encodes something a
  multi-stroke or multi-colour drawing needs.
- `originalModelBaseScaleFactor` (0.7997) is not the canvas-to-page ratio and its role is unexplained.
- How several strokes with different colours share one annotation: the samples have at most two strokes, both
  the same colour. Round six's synthesis rewrote every stroke identically.
- The `/AP` appearance stream still has to be produced by us; Apple's is a raster image XObject.

## Next, for folino

Write an encoder from folino's `InkStroke` to this structure, then place the annotation with the three-box
rule. folino creates its own annotations rather than editing Apple's, so it controls all three boxes from the
start. Verify the same way this was verified: on a device, with the eraser.

# Built, not edited (2026-09-01)

The round above left one thing untested, and it was the one that mattered: every accepted payload had been an
Apple payload with our geometry in it. So the next round built the payload from named quantities — point
records included — and created the annotation from nothing, on a document Apple had never touched.

| variant | payload | document | result |
| --- | --- | --- | --- |
| A | Apple's, verbatim | folino's own export, 595.4458 x 841.6944 | accepted |
| B | ours, built | Apple's `ink-samples 2.pdf` | accepted |
| C | ours, built | folino's own export | accepted |

**That is the format solved.** Not "we can edit Apple's ink" but "we can write ink Apple's tools edit": our
bytes, our annotation, our document, our page size, and the eraser and the lasso both find it.

Variant A also cleared three things at once that no earlier round could separate — creating the annotation
ourselves, using a document with no Apple provenance, and computing the rect against a MediaBox that is not
A4's nominal size. None of them matter. The payload was the only variable left, which is what made the two
defects below findable.

## Two defects in our writer, both structural

`tools/diffbuilt.py` compares structure before values, and both fell out of the first comparison:

- **The stroke carries `.2` twice** — we emitted one. `tools/constfields.py` had already printed `2x` against
  that field, and it was read as repetition noise rather than as structure.

  **What those two fields are was described wrongly here, and `tools/checkstrokeids.py` corrects it.** They are
  not "two distinct identifiers". Across the eight samples the first is the *same* value on every one
  (`bd66b0cd…`) and the second is *all zeros* — and sample 5 carries **three** of them, with an extra value
  ahead of the constant. So `.2` is a repeated field of varying length whose first entry is not per-stroke
  identity at all. Sample 5 is the page where the mark was drawn, undone and redrawn, which is suggestive but
  not established.

  None of this changes the encoder: two fields carrying fresh UUIDs were accepted on device, which is the only
  evidence that decides it. It changes what a future reader should believe — the rationale, not the bytes. If
  the golden test is ever re-pinned to a different sample, note that sample 5 would not match a two-field
  encoder.
- **The trailing constant pair is a value, little-endian.** `0xFE54` is the bytes `54 fe`. Transcribing this
  document's own note as a byte literal reversed it.

Neither is visible in a values-only diff, and neither would have been found by another device round. When a
black-box oracle rejects something, compare shape first.

## The UUIDs identify the ink, and must be unique per annotation

The probe generated its UUIDs deterministically so a rebuilt variant would be byte-identical, which made pages
1 and 2 carry byte-identical payloads. Erasing on page 2 then edited **page 1's** ink.

So AnnotationKit keys a drawing by the identifiers inside the payload, not by the annotation or the page that
holds it. Two annotations sharing them are one drawing as far as the markup is concerned.

**Every annotation folino writes needs freshly generated UUIDs.** Reusing them — the obvious optimization when
one score's strokes all come from one drawing — makes the eraser delete a mark on another page. This was found
by accident, not by design; nothing else in the investigation would have caught it, and it would have shipped.

Be precise about what that experiment showed, though: the two colliding pages shared *every* identifier, so it
does not say which one keys the drawing. Apple's own `.2` is the same value on all eight samples, so that one
is certainly not the key — leaving `.9`, `.2.3.5.13` and `.2.3.5.14`. Generating all of them fresh is correct
either way, and cheaper than finding out which.

## What is still copied rather than understood

`.2.3.1`, the `.2.3.3` pair and `.2.3.10` on the stroke, and `.2.3.5.1/.2/.3/.9` on the points container are
carried as one fixed set lifted from a sample. `constfields.py` shows they take two to five distinct values
across the eight samples, so they encode *something*; one fixed set is now known to work for a single-stroke
pen drawing in two different documents.

Dropping them entirely was tested in the same round and produced no ink, so they are not optional — keep them.

## The annotation stays `/Ink` (2026-09-01)

Apple writes `/Square`. folino writes `/Ink`, which is the semantically correct annotation for a pen mark and
the one other PDF tools select and delete properly. Whether `AKExtras` is honoured on `/Ink` decided whether
the export could keep what it has or would have to move to `/Square` and carry its appearance separately.

**It is honoured.** An `/Ink` annotation carrying the payload erases, selects and *moves* in Apple's markup,
alongside `/Square` annotations on other pages, with no interference between them. So the change to the
shipped export is additive: the same annotation it already builds, plus one key.

Two annotations on one page, with distinct identifiers, are independently erasable, selectable and movable.
Nothing bleeds between pages. The identifiers do all the work of keeping marks apart.

### The round before this one measured nothing, and it is worth knowing why

To make the subtype the only variable, its two variants were given byte-identical payloads. Identifiers name
the drawing — established one round earlier — so identical payloads are the definition of "the same drawing",
and a third variant kept a default salt and joined them. Three of the four were one drawing; edits crossed
between pages exactly as that arrangement requires.

Identifiers are free, so *identical apart from the identifiers* is the comparison that isolates a subtype.
*Identical including them* is not a comparison. `tools/checkids.py` now fails a round whose variants share an
identifier, which is the same rule production code has to follow.

## The key "needs" two serialization passes — RETRACTED (2026-09-02)

**This whole section is an artifact of a broken iOS 27.0 simulator runtime.** Read it as history; the
retraction at the end is the current fact.

Everything in the sections above this one was measured with command-line tools that opened a PDF, set the
key and saved. Inside the app — and inside the Reader test bundle, which is where this surfaced — the same
three lines silently lose the payload. `/AAPL:AKExtras` set on a `PDFAnnotation` that PDFKit created THIS
session does not survive `dataRepresentation()`.

The control is what makes it unambiguous. Serializing an `/Ink` annotation with **nothing set on it at all**
still produces an `/AAPL:AKExtras` in the output, holding AnnotationKit's own trio:

```
/AAPL:AKExtras << /AAPL:AKIdentityHash (…64 hex…)
                  /AAPL:AKPDFAnnotationDictionary << /F 4 /Subtype /Ink /Rect […] … >>
                  /AAPL:AKAnnotationObject (YnBsaXN0MDD… NSKeyedArchiver …) >>
```

Byte-for-byte the same output whether our key carried a real 1341-byte archive, seven bytes of garbage, or was
never set: 6595 bytes, `AKAnnotationV2` absent from the file every time. So this is AnnotationKit *adopting*
each freshly built annotation on the way out, not reacting to what we wrote — and the adoption overwrites the
key wholesale. `write(to:)` behaves identically; it is the same serializer.

**Setting the key on an annotation parsed back from serialized bytes is not adopted.** Stamp the annotations,
serialize, reopen the result, set `/AAPL:AKExtras` on the parsed annotations, serialize again: the value is
written verbatim (1788 base64 chars, exactly what went in), and the synthesized trio is replaced rather than
merged. So `AnnotatedPDFComposer` was written to do exactly that, mapping payload to annotation by position in
the page's `/Annots` order.

**Retraction.** Every measurement above was taken on an **iOS 27.0** simulator runtime, where
`PDFAnnotation.add(_:)` itself fails silently — `Cannot save value for annotation key: /InkList. Invalid
type.` — and that failure is what cascades into AnnotationKit adopting the annotation and overwriting the key.
Re-measured on `OS=26.5`:

- a single pass works: the value survives `dataRepresentation()` byte-for-byte, a two-payload control shows
  each annotation reading back its own distinct marker, and no identity trio appears;
- one-pass and two-pass output are equivalent — same annotation key sets, same `AKExtras` archive bytes, same
  `/InkList`, same vector `/AP` path-operator counts, pixel-identical rendering, same annotation order and
  `/Rect`, same translucency. The only difference is an inert `/ExtGState` (`CA 1.0`) plus a `gs` operator the
  ONE-pass output carries for opaque strokes: extra, invisible, ~135 bytes.

The second pass was therefore removed, along with the position-based payload-to-annotation mapping. The
composer sets `/AAPL:AKExtras` on each annotation as it builds it and serializes once. If this symptom ever
reappears, check the runtime for the `/InkList` error before touching the composer.

One more trap on the read side, which is real and outlived the retraction: PDFKit does **not** enumerate
`/AAPL:AKExtras` in `annotationKeyValues` for an annotation parsed from a file, though
`value(forAnnotationKey:)` returns it. A test written the obvious way reports the key missing from a document
that demonstrably contains it.

## What AKAnnotationV2 costs: selection in macOS Preview (2026-09-02)

Measured on one file with one variable removed, then checked against Apple's own output:

| file | Preview selection |
| --- | --- |
| our export with `/AAPL:AKExtras` | **no** — neither normal nor markup mode |
| the same file, `AKExtras` stripped (`tools/stripakextras.swift`) | yes, both modes |
| Apple Books, `/Stamp` + `/PPK` (the old `crdt` form) | yes |
| Apple Books, `/Square` + `AKAnnotationV2` (what we replicate) | **no** |

So this is not a defect in what we write. **Apple's own `AKAnnotationV2` annotations are not selectable in Preview
either**, and the subtype is not what Preview keys off — Apple uses `/Square` there and it makes no difference.
An annotation carrying this payload is claimed by Preview's markup layer and stops being an object the arrow
tool can pick up.

The old `crdt` form is the only one measured to have both, and it is unreachable: `PKDrawing` cannot produce
that container and AnnotationKit is a private framework. So with the format that is actually available, Pencil
erasing on iOS and object selection in Preview do not coexist.

One thing our choice keeps that Apple's does not: the annotation stays `/Ink` with a real `/InkList`, so an
editor that does not special-case `AKExtras` still sees a pen mark rather than a rectangle. Preview is
unusual precisely because it *does* recognise the key. This is reasoning from the file's structure, not a
measurement — no third-party editor has been tested.

**This falsified the spec's original "there is nothing to trade away".** There is: object selection in
Preview, in exchange for erasing with a Pencil on iOS. `docs/superpowers/specs/2026-09-01-erasable-ink-export-design.md`
now records that trade, and which side it takes.

---

# The drawing is a PencilKit archive, and the hand-built protobuf is gone (2026-09-02)

## What the device rounds showed first

Three defects survived the first accepted export: the highlighter sat tens of points from where Preview drew
it, it was drawn as a round pen rather than a chisel, and pens came out a different thickness. Fourteen
one-variable device rounds (`tools/mk*variants.py`, applied with `tools/applyone.swift`) settled them:

- **Geometry was never wrong.** The payload's points and the annotation's `/InkList` agree to four decimals
  (`tools/comparegeometry.py`, `tools/dumpinklist.swift`); Preview draws the vector `/AP` PDFKit generates
  from the same points. Files re-renders the payload with PencilKit from the moment it adopts it — the
  thumbnail in the Files list is right, the opened document is not — so the disagreement is entirely on the
  PencilKit side.
- **The marker's identifier is `com.apple.ink.marker`** (a Files.app reference, hand-drawn by the user,
  `tools/crdtpoints.py`). Files' extra ink fields for a marker (`"linear"`, colour × 0.15, colour × 0.85, a
  −0.5 double) change nothing visible.
- **The position error was the bounding box.** Our box was the point extent grown by half the width plus a
  point. AnnotationKit recomputes `PKDrawing.bounds` from the drawing and places the mark by it, and a
  marker's rendered extent is not the point extent plus half its width. With PencilKit's own bounds in the
  payload the mark lands exactly (variant F). The azimuth/altitude slots were red herrings: rewriting them
  moved the chisel and the mark, but only between two states, and never to the right one.
- **The finger-drawn chisel is azimuth 0** (variant F1, judged exact by eye). Pencil-drawn strokes carry their
  real azimuth, and the neutral `InkStroke` already stores it.

## Books on iPadOS 26 writes `wrd`

An iPad Books sample (`samples/books-ipad-wrd-pen-pen-marker.bin`) carries, in the archive's `drawing` slot,
not gzip-wrapped protobuf but the bytes `PKDrawing.dataRepresentation()` returns — the `wrd` container. macOS
PencilKit decodes it (`tools/pkdump.swift`) and produces it (`tools/mkwrd.swift`), so every field of the stroke
encoding is PencilKit's own and nothing about it is synthesized any more. The decoded sample also settled the
remaining slot meanings for the record: azimuth and altitude are `u16 / 65535 × π` (π/3 for the Pencil), a
marker's size is `(w, w × 1.032)`, and the per-stroke box is `renderBounds`, integral.

Two traps for anyone building PencilKit drawings on a Mac:

- A plain command-line tool crashes in `PKDrawing` construction (`CFEqual(NULL)` on PencilKit's replicas queue)
  because it has no bundle identifier. Wrap the binary in a minimal `.app` — `tools/PKProbe/Info.plist` is
  enough — and it runs.
- `swift file.swift` cannot JIT PDFKit or PencilKit; build with `swiftc -framework PDFKit` / `-framework
  PencilKit` instead.

`AnnotatedPDFComposer` now scales the placed `PKDrawing` into canvas units (points and sizes alike, transform
baked in), stores `dataRepresentation()` as the drawing, and derives the archive rectangle and `/Rect` from
`PKDrawing.bounds`. `AKInkPayloadEncoder`, `ProtobufWriter`, `GzipWriter` and the structural golden test are
deleted. Pixel-erased strokes, which the neutral format could not express, now export with their mask intact
because PencilKit's archive carries it. Verified on device: position, chisel, erase and select (F1, G4).

## Thickness: PencilKit's width curves, and why the same stroke looks different in three places

Measured on the live `PKCanvasView` in the simulator (`tools/PKProbe`, screenshots via `simctl io screenshot`,
`tools/bands.py`; a unit test's window never reaches the simulator screen, hence a real app), and identical in
`PKDrawing.image(from:scale:)` on iOS and macOS. Widths are in the drawing's own units and scale linearly with
zoom (every row exactly doubled at zoom 2). `force` changes nothing for any ink.

| ink | rendered width for point size `s` | measured at s = 4 / 8 / 16 |
| --- | --- | --- |
| pen, monoline | `2s − 4` | 4 / 12 / 28 |
| pencil | ≈ `2s − 1` | 7.3 / 15 / 29 |
| marker (azimuth 0, along the stroke) | `s / 2` | 2 / 4 / 8.3 |
| fountain pen | ≈ `s / 2 − 0.7` | 1.3 / 3.3 / 7.3 |
| watercolor | ≈ `1.7s` | 6.7 / 13.3 / 27.3 |
| crayon | ≈ `1.85s` | 7.3 / 14.7 / 30.3 |

The constant term is what made the same stroke look different everywhere: it is 4 *content units*, and the
content unit differs by renderer. Apple's markup draws the archived drawing in canvas units (4/3 of a page
point) and scales the result onto the page, so a pen of page-point size `w` shows `2w − 3` points; folino's
own `PKCanvasView` draws in the score's document units — on an iPhone about 1.7 page points each — so the same
stroke shows `2w − 6.8`, and on an iPad, whose document is wider than the page, thicker than the PDF. Every
measurement on device fit this to a fraction of a point once the canvas scale was accounted for.

Decision (2026-09-02): the export does **not** compensate for the exporting device's document scale — the
on-screen look is itself device-dependent, and matching it would need the reader's live layout inside the
export path. What the export does do is make its own two renderings agree: the appearance stream's line width
now goes through the same curve (`AnnotatedPDFComposer.appearanceLineWidth`), so Preview and Files show the
same thickness, where before the marker's vector was twice PencilKit's band.

## Tools added in this round

| tool | what it does |
| --- | --- |
| `dumpinklist.swift` | `/InkList`, `/Rect`, border width and colour of every ink annotation |
| `apbody.swift`, `xobjimages.swift` | the `/AP` content stream, and the pixel size of any raster it draws |
| `comparegeometry.py`, `padding.py` | payload points mapped to page space; bbox padding against the width |
| `crdtpoints.py` | the bitmask-driven point layout of a `crdt` container (Files.app's form) |
| `pkdump.swift`, `mkwrd.swift`, `pkrender.swift` | decode / build / render a PencilKit archive on macOS (run from `mkwrd.app`) |
| `mkwrdarchive.py`, `exportpoints.py`, `setscale.py` | swap a PencilKit drawing into an archive; helpers |
| `applyone.swift` | replace one annotation's archive (and `/Rect`, keeping `/InkList` in place) in a PDF |
| `mk*variants.py`, `mkshiftvariant.py` | the one-variable device variants |
| `measurewidth.swift`, `renderpage.swift`, `redwidth.py`, `bandbox.py`, `bands.py`, `linewidth.py`, `mklines.py` | thickness and position measurements on renders and screenshots |
| `PKProbe/` | the simulator app that measures the live `PKCanvasView` (xcodegen; `-page A|B`, `-zoom n`) |
