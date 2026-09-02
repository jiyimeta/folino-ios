# Erasable ink in the annotated PDF export — design

2026-09-01. Makes the ink in folino's annotated PDF export editable by Apple's own markup — erased with the
PencilKit eraser, selected, moved — in Files and Books, on any device, by writing Apple's `AKAnnotationV2`
payload alongside the `/Ink` annotation the export already produces. (For macOS Preview specifically, see
"What the payload does cost" below.)

The format was reverse-engineered on this branch. The measurements, the tools and the false turns are in
`docs/engineering/crdt-ink-format/README.md`; this document assumes them and does not repeat the derivation.

## The problem

The shipped export (merged 2026-09-01, `ea85a47a`) writes each stroke as a PDF `/Ink` annotation with a vector
appearance. That is a real PDF object: any editor can select it and delete it whole. What no editor can do is
*erase part of it*, which is what a person expects when they open a marked-up score on another device and
reach for the Pencil.

Apple's own apps can. A PDF annotated in Books carries a private payload that AnnotationKit reads, and its
markup UI edits the ink through that payload rather than through the PDF annotation. Without it, folino's marks
are second-class next to Apple's on Apple's own platform.

The payload is reachable. It is `NSKeyedArchiver` → gzip → header-less protobuf, all public technology, and
nothing in it is a device identifier or a signature. Ink built entirely from our own bytes, in an annotation we
created, in a document Apple never touched, is accepted: it erases, selects and moves like Apple's own.

## What this covers, and what it does not

**In scope.** An encoder from `Domain.InkStroke` to the `AKAnnotationV2` payload, and its wiring into
`AnnotatedPDFComposer` so every ink annotation the export writes carries one.

**Out of scope.** Reading Apple's payload back (folino imports ink through its own FINK codec and has no need
to). The Android export path, which does not exist yet. Any change to how ink is captured, stored, anchored or
rendered on screen. Any change to the export's menu, file naming or formats — this adds a capability to the
bytes, not an option to the UI.

**Explicitly unchanged.** The annotation stays subtype `/Ink`. Apple writes `/Square`, and the export could
have followed, but `/Ink` is the correct annotation for a pen mark, and it is what an editor that does not
special-case `AKExtras` falls back to reading: a real `/InkList` describing a stroke, rather than a rectangle.
(That last part is reasoning from the file's structure — no third-party editor has been tested.) The payload
is honoured on `/Ink`, so keeping the subtype costs nothing.

**What the payload does cost: object selection in macOS Preview.** An annotation carrying `/AAPL:AKExtras` is
claimed by Preview's markup layer and stops being an object the arrow tool can pick up, in normal and markup
mode alike. This is inherent to the format, not to our encoding — Apple's own `/Square` + `AKAnnotationV2`
output behaves identically, the same file with `AKExtras` stripped selects fine, and the subtype is not what
Preview keys off. The one form measured to have both properties is Books' old `/Stamp` + `/PPK` `crdt`
container, which is unreachable: `PKDrawing` cannot produce it and AnnotationKit is private. The measurement
table is in `docs/engineering/crdt-ink-format/README.md` § "What AKAnnotationV2 costs".

So Pencil erasing on iOS and object selection in Preview do not coexist in any reachable form, and this export
chooses erasing. Annotating a score on an iPad with a Pencil — and rubbing a mark out again — is what the
feature is for; picking a mark up with a mouse pointer in Preview is not.

## The rule the encoder must satisfy

Three boxes describe the same rectangle and must agree to well under 0.1pt, or the annotation is discarded in
silence — it neither erases nor selects, and only its appearance stream keeps it visible:

```
bbox         the payload's own stored bounding box, canvas units, y down
archiveRect  = (bbox.x·sx,  pageH − (bbox.y + bbox.h)·sy,  bbox.w·sx,  bbox.h·sy)
/Rect        = (archiveRect.x − 1, archiveRect.y − 1, archiveRect.w + 2, archiveRect.h + 2)

sx, sy = pageW / drawingSize.width, pageH / drawingSize.height
```

`pageW`/`pageH` are the page's **real MediaBox**. A4's nominal 595.2756 × 841.8898 against a page that is
actually 595 × 842 puts the rectangle about 0.1pt out, and the annotation is rejected outright. No rounding
anywhere on the path.

## Design

### One box, derived once

Today the annotation's bounds come from `PKDrawing.bounds` inset by a point. The payload's bbox cannot be
derived independently of that, because PencilKit's render bounds include padding we would have to reproduce
exactly, and "close" is rejection.

So the export computes **one** box and derives all three from it:

```
inkBox = bounds of the stroke's points, grown on every side by (max(width) / 2 + 1)
```

in page-local units, from `InkStroke` geometry alone. Half the widest sample is the ink's own extent; the
extra point is anti-aliasing slack, the same allowance the export already makes. `inkBox` becomes the payload bbox (scaled into canvas
units), `archiveRect` by the formula above, and the annotation's `/Rect` by growing that by 1pt. The vector
appearance is then drawn relative to the `/Rect` folino chose, rather than the `/Rect` being chosen to fit an
appearance — which is the direction that keeps the three boxes exactly consistent.

This replaces the current `placed.bounds.insetBy(dx: -1, dy: -1)` derivation. The visible result should be
unchanged; the appearance is generated from the same geometry either way.

### Where the code lives

`Packages/Features/Reader/Sources/ReaderAnnotationCore/` — Foundation and Domain only, already cross-compiled
for Android. The encoder takes `[InkStroke]` and a page size and returns `Data`. It touches no PencilKit, no
CoreGraphics beyond the shimmed value types, and no PDFKit, so Android gets it unchanged when its export lands,
per the parity rule in `CLAUDE.md`: share the logic, never reimplement it.

New files, all in that target:

| file | responsibility |
| --- | --- |
| `AKInkPayloadEncoder.swift` | `[InkStroke]` + geometry → the protobuf drawing payload |
| `AKInkArchive.swift` | the `NSKeyedArchiver` object graph around it, as a binary plist |
| `AKInkGeometry.swift` | the three-box arithmetic, given a page size and an ink box |
| `ProtobufWriter.swift` | minimal length-delimited/varint/fixed writer — no dependency |
| `GzipWriter.swift` | gzip framing (header, CRC32, ISIZE) over a `Deflating` seam |

`AnnotatedPDFComposer` gains a payload encode per stroke, and one call and one annotation key to attach it:
each annotation gets `/AAPL:AKExtras` set to `["AAPL:AKAnnotationV2": base64]` as it is built, before it is
added to its page, and the document is serialized once. `compose`'s return type changes from `Data` to
`(data: Data, akEncodeFailures: Int)`, so the count of marks that went out without an `AKAnnotationV2`
payload — a silent loss of editability, not of the mark itself — travels back to the caller.

**History — the two-pass design, and why it is gone.** An intermediate revision attached the payloads on a
second serialization pass: stamp and serialize, reparse the bytes, locate each annotation by page index plus
its recorded position in that page's `/Annots` order (a `PayloadSlot`), confirm it with an identity check
against the recorded bounds, attach the payload there, and serialize again. That existed because of one
measurement — that `/AAPL:AKExtras` set on an annotation PDFKit had just created did not survive
`dataRepresentation()`, apparently because AnnotationKit adopted every freshly built annotation on the way out
and rewrote the key with its own `AKIdentityHash` / `AKPDFAnnotationDictionary` / `AKAnnotationObject` trio.

That measurement was an artifact of a broken **iOS 27.0 simulator runtime**, where `PDFAnnotation.add(_:)`
itself fails silently (`Cannot save value for annotation key: /InkList. Invalid type.`) and the failure
cascades into the adoption described above. Two probes on `OS=26.5` settled it: a single pass works, with the
value surviving byte-for-byte and a two-payload control confirming each annotation reads back its own distinct
marker and no identity trio appears; and one-pass and two-pass outputs are equivalent — identical annotation
key sets, identical `AKExtras` archive bytes, identical `/InkList`, identical vector `/AP` path-operator
counts, pixel-identical rendering, identical annotation order and `/Rect`, and the same translucency. The only
difference is an inert `/ExtGState` (`CA 1.0`) plus a `gs` operator the one-pass output carries for opaque
strokes — extra, invisible, about 135 bytes.

So the second pass bought nothing while costing a full extra document serialization on the main thread, plus a
position-based payload-to-annotation mapping whose failure mode is a payload landing on somebody else's mark —
which, because AnnotationKit names a drawing by the identifiers inside the payload, would mean an eraser
stroke deleting a mark the user never drew. It was removed. If this symptom ever resurfaces on a later OS, the
runtime is what wants checking first; do not reintroduce the two-pass flow without re-measuring on a known-good
runtime.

### The payload

Per stroke, one annotation, one drawing, one stroke inside it. The samples are all single-stroke, so this is
the shape that is actually tested; it also means a stroke's identity survives independently, which is what
makes marks independently erasable.

```
.1                       0
.2.1  .2.2               10, 10
.2.3.1                   10
.2.3.2   (×2)            two identifiers
.2.3.3   (×2)            scaffolding constant
.2.3.4.1                 RGBA, four float32 in 0…1, from InkStroke.colorRGBA × opacity
.2.3.4.2                 "com.apple.ink.pen"
.2.3.4.3                 3
.2.3.5.1 .2 .3 .9        scaffolding constants
.2.3.5.4                 point count
.2.3.5.5                 count × 24 bytes:
                           [0:4]   float32  time, seconds from the stroke's start
                           [4:8]   float32  x, canvas units
                           [8:12]  float32  y, canvas units, y down
                           [12:14] uint16   width
                           [14:16] uint16   1000
                           [16:18] uint16   0
                           [18:20] uint16   force
                           [20:22] uint16   0xAAAA
                           [22:24] uint16   0xFE54
.2.3.5.6                 bbox, four float32, canvas units, INCLUDING the pen padding
.2.3.5.11                fixed64 CFAbsoluteTime
.2.3.5.13 .14            two identifiers
.2.3.9                   one identifier
.2.3.10                  scaffolding constant
```

The trailing pair are **values**, little-endian: `0xFE54` is the bytes `54 fe`. Writing them as a byte literal
reversed them and the annotation was rejected — one of the two defects that cost a device round.

`InkStroke` already carries `x`, `y`, `width`, `force`, `timeMillis`, `colorRGBA` and `opacity`, so every
quantity above except the scaffolding comes straight from it.

### Identifiers

**Five fresh UUIDs per annotation, never reused.** AnnotationKit names a drawing by the identifiers inside its
payload, not by the annotation or the page holding it: two annotations sharing them are one drawing, and an
edit to either lands on whichever the markup resolves first — across pages.

This is a correctness requirement. Reusing identifiers is the obvious optimization when every stroke on a score
comes from one drawing, and it would make the eraser delete a mark on another page. It was found by accident,
when a probe generated identifiers deterministically for reproducibility; nothing else in the investigation
would have caught it.

Uniqueness holds by construction — each payload's five identifiers are fresh `UUID()` values, and the odds of
a collision make a runtime check pointless. `AnnotatedPDFComposer` does not assert it: an O(n) cross-check
over every annotation in the composed document would cost real work for no coverage a `UUID()` doesn't
already give. `AnnotatedPDFComposerAKTests` covers this with a test instead
(`no two annotations in a document share an identifier`), generating identifiers across many strokes and
confirming none repeat.

### Coordinate space

`drawingSize` = page size × 96/72, matching Apple's own convention (their ratio measures 0.7504 ≈ 72/96).
Canvas y runs downward, which is also folino's page-local convention, so placement is a single scale with no
flip; the flip happens once, in `archiveRect`.

A 1:1 canvas would work arithmetically and has no advantage, so it is not used — the ratio Apple ships is the
one that has been exercised.

### gzip

Foundation has no public gzip. iOS has `Compression` (raw DEFLATE, no framing); Android's Swift does not.

The framing — header, CRC32, ISIZE — is portable and lives in `GzipWriter`. The compressor is a `Deflating`
protocol with one method; iOS implements it over `Compression`. Android supplies its own when it needs one,
which is not now. If a zero-dependency fallback is ever wanted, stored (uncompressed) DEFLATE blocks need no
compressor at all and any conforming inflate accepts them; the seam leaves that open without taking it.

### Integration

`AnnotatedPDFComposer.makeAnnotation` (`Packages/Features/Reader/Sources/Reader/Annotation/Export/`) already
decodes the stored drawing, applies the placement transform and builds the `/Ink` annotation. It gains:

1. decode the stored bytes to `[InkStroke]` through `Domain.InkStrokeCodec` and apply the same placement
   transform arithmetically — no PencilKit on this path;
2. compute `inkBox`, and from it the three boxes;
3. encode, and set `/AAPL:AKExtras` to `["AAPL:AKAnnotationV2": base64]`.

The existing PencilKit decode stays where it is, feeding the vector appearance. Two consumers of one placement
is a small duplication, and folding the appearance onto `InkStroke` too is a worthwhile follow-up — but it is
not this change, and doing it here would put a rendering rewrite inside a format change.

## Failure handling

Encoding a stroke can fail only through a programming error, but the export must not be the place that
surfaces it. A stroke whose payload cannot be built is written exactly as today: an `/Ink` annotation with its
vector appearance and no `AKExtras`. The export never fails, and the result is never worse than what ships now.

Failures increment `annotated_export_ak_encode_failed` alongside the existing `annotated_export_drifted`.

## Testing

Swift Testing, in `ReaderTests` (which already depends on `ReaderAnnotationCore`) — the encoder needs no host
app, and the whole suite runs through `xcodebuild test` on the iPhone 17 Pro Max destination as everything in
this repo does.

- **Point record layout.** A known stroke encodes to known bytes, including the trailing constants in the
  right order.
- **Three-box arithmetic.** The formula against a real MediaBox, and a regression case pinning that nominal A4
  is *not* used.
- **Identifier uniqueness.** A document with many strokes yields no repeated identifier.
- **gzip round trip.** Our framing decompresses through Foundation's own inflate.
- **Structural golden test.** Our encoder's output, compared against a checked-in Apple sample, must match in
  **field order and wire types** at every level — values are free to differ.

The last one is the important one. Both defects in the research writer — a missing repeated field, and two
reversed bytes — were invisible to a values-only comparison and were caught the moment structure was compared
first. It is the regression guard for every scaffolding constant we carry without understanding.

**Device verification is still required and cannot be replaced.** No simulator or unit test can tell us
AnnotationKit accepted a payload; the only oracle is the eraser on a real device, and the export path has
already produced three bugs that reproduced nowhere else.

## Size

About 1.5–3 KB per stroke after gzip. A heavily marked score at fifty strokes gains roughly 100 KB. Acceptable
against a PDF that is already megabytes, and it buys the entire feature.

## Known limits, accepted

- **Scaffolding constants are copied, not understood.** `.2.3.1`, the `.2.3.3` pair, `.2.3.10`, and
  `.2.3.5.1/.2/.3/.9` are one fixed set lifted from a sample. They are known to work for a single-stroke pen
  drawing in two different documents at two different page sizes. Dropping them produced no ink, so they are
  not optional. The structural golden test is what keeps them honest.
- **Tool identity is lost on edit.** Every stroke is written as `com.apple.ink.pen`. folino's monoline and
  marker tools have no known identifier, and until a person edits the mark, folino's own appearance stream is
  what renders — so the ink looks right until Apple's markup redraws it, at which point it becomes a pen of
  the same width and colour. Worth telling the user only if it proves visible in practice.
- **Multi-colour drawings are untested as a single annotation.** They do not arise: one annotation per stroke,
  one colour each.

## Android

The encoder is shared from the day it lands, but Android has no PDF export to call it from. A
`PARITY(android)` marker goes on the composer, so `docs/engineering/ios-android-parity.md` carries the row
until Android's export exists.

## Rejected alternatives

**Subtype `/Square`, as Apple writes it.** Would have meant giving up the `/Ink` semantics other PDF tools
rely on, and generating an appearance for a shape annotation that is really ink. Tested and unnecessary:
`AKExtras` is honoured on `/Ink`.

**Two annotations, one for appearance and one for the payload.** Doubles the object count, and either the ink
draws twice or one annotation is invisible to non-Apple tools. Unnecessary for the same reason.

**The older `crdt` container.** `/Stamp` + `/PPK`, which Books wrote before `AKAnnotationV2`. Its container is
not reachable from public API — `PKDrawing.dataRepresentation()` emits `wrd`, and `PKDrawing(data:)` cannot
even read Apple's — and AnnotationKit is a private framework absent from the iOS SDK. A controlled swap
confirmed the container is the gate. Dead end, and superseded by Apple's own current format.

**Rasterizing the ink into the page.** Loses the vector score and makes the marks permanent. Rejected when the
export was designed.

## Open questions, none blocking

- What the scaffolding fields mean, and whether any of them would need to change for a tool other than the pen.
- `originalModelBaseScaleFactor` (0.7997) is not the canvas-to-page ratio and is carried unexamined.
- Whether Apple's markup, having edited a mark, writes it back in a form folino's own importer could read.
  folino does not import from PDF today, so this is a question for a later feature, not this one.
