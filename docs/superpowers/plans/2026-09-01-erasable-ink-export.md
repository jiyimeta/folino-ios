# Erasable Ink Export Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the ink in folino's annotated PDF export erasable, selectable and movable by Apple's own markup on any device, by attaching Apple's `AKAnnotationV2` payload to the `/Ink` annotation the export already writes.

**Architecture:** A new encoder in `ReaderAnnotationCore` (Foundation + Domain only, already cross-compiled for Android) turns a `Domain.InkStroke` plus a page size into `Data`: a header-less protobuf drawing, gzipped, inside an `NSKeyedArchiver` binary plist. `AnnotatedPDFComposer` computes one box per stroke, derives the payload's bounding box, the archive's rectangle and the annotation's `/Rect` from it, and sets one extra annotation key. Nothing else about the export changes.

**Tech Stack:** Swift 6.3, SwiftPM, Swift Testing, `PropertyListSerialization`, Apple's `Compression` framework (iOS side only), PDFKit.

**Spec:** `docs/superpowers/specs/2026-09-01-erasable-ink-export-design.md`

**Format reference:** `docs/engineering/crdt-ink-format/README.md` — the measurements behind every constant here. Read it before Task 3.

## Global Constraints

- **Deployment floor is iOS 18.0.** No raw iOS 26 API; anything newer goes behind `Packages/Utility/Sources/UtilityUI/GlassEffectCompat.swift`. Nothing in this plan should need it.
- **`ReaderAnnotationCore` may import Foundation and `Domain` only.** No PencilKit, no UIKit, no PDFKit, no `Compression`. It is cross-compiled for Android; an import that does not exist there breaks the Android build.
- **New symbols get no access modifier unless something outside the module references them.** `public` is a decision. Tests reach internals through `@testable import`.
- **New tests use Swift Testing** (`import Testing`, `@Suite`, `@Test`, `#expect`).
- **`swift test` does not work in this repo.** Every test runs through `xcodebuild test` on an **iPhone 17 Pro Max** simulator destination with `-skipPackagePluginValidation`.
- **Comments reflow at 120 columns**, not 80.
- **American English** in prose and identifiers, except where an Apple API spells it otherwise (`cancelled`).
- **Do not push.** Commit per task; the branch is merged by a human.

### Constants copied verbatim from the format reference

These are the fields whose meaning is unknown. They are **not optional** — dropping them produced no ink on device — and they are not derivable. This is the exact set that has been accepted.

```
stroke level          .1  = varint 10
                      .3  = bytes 08 01 10 00 18 01      (first occurrence)
                      .3  = bytes 08 00 10 01 18 00      (second occurrence)
                      .10 = bytes 08 00 10 01 18 00
points container      .1  = bytes 08 00 10 00 18 01
                      .2  = bytes 08 00 10 00 18 00
                      .3  = varint 0
                      .9  = varint 0
drawing level         .1  = varint 10,  .2 = varint 10
top level             .1  = varint 0
```

Archive scalars, likewise verbatim: `akPlat = 2`, `akVers = 2`, `formContentType = 0`, `originalExifOrientation = 1`, `originalModelBaseScaleFactor = 0.7997311827956989`, `AKIsFormFieldKey = false`, `editsDisableAppearanceOverride = true`, `shouldUsePlaceholderText = true`, `textIsClipped = false`, `textIsFixedHeight = false`, `textIsFixedWidth = false`, `customPlaceholderText = $null`.

---

## File Structure

| file | responsibility |
| --- | --- |
| `Packages/Features/Reader/Sources/ReaderAnnotationCore/AK/ProtobufWriter.swift` | minimal protobuf encoder: varint, fixed32/64, length-delimited, nested messages |
| `Packages/Features/Reader/Sources/ReaderAnnotationCore/AK/GzipWriter.swift` | gzip framing (header, CRC32, ISIZE) over a `Deflating` seam |
| `Packages/Features/Reader/Sources/ReaderAnnotationCore/AK/AKInkGeometry.swift` | the ink box and the three-rectangle arithmetic |
| `Packages/Features/Reader/Sources/ReaderAnnotationCore/AK/AKInkPayloadEncoder.swift` | `InkStroke` → the protobuf drawing payload |
| `Packages/Features/Reader/Sources/ReaderAnnotationCore/AK/AKInkArchive.swift` | the `NSKeyedArchiver` plist envelope around the payload |
| `Packages/Features/Reader/Sources/Reader/Annotation/Export/AppleDeflater.swift` | the iOS `Deflating` implementation, over `Compression` |
| `Packages/Features/Reader/Sources/Reader/Annotation/Export/AnnotatedPDFComposer.swift` | modified: one box, one extra annotation key |
| `Packages/Features/Reader/Tests/ReaderTests/AK*Tests.swift` | the suites below |
| `Packages/Features/Reader/Tests/ReaderTests/Resources/apple-ink-sample.bin` | a real Apple archive, for the structural golden test |

---

### Task 1: Protobuf writer

**Files:**
- Create: `Packages/Features/Reader/Sources/ReaderAnnotationCore/AK/ProtobufWriter.swift`
- Test: `Packages/Features/Reader/Tests/ReaderTests/AKProtobufWriterTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `struct ProtobufWriter` with `mutating func varint(_ field: Int, _ value: UInt64)`, `fixed32(_ field: Int, _ value: UInt32)`, `float(_ field: Int, _ value: Float)`, `fixed64(_ field: Int, _ value: UInt64)`, `double(_ field: Int, _ value: Double)`, `bytes(_ field: Int, _ value: Data)`, `message(_ field: Int, _ body: (inout ProtobufWriter) -> Void)`, and `var data: Data`.

- [ ] **Step 1: Write the failing test**

```swift
import Foundation
import Testing
@testable import ReaderAnnotationCore

@Suite("Protobuf writer")
struct AKProtobufWriterTests {
    @Test("a varint field encodes as tag then value")
    func varintField() {
        var w = ProtobufWriter()
        w.varint(1, 10)
        // field 1, wire type 0 -> tag 0x08; value 10 -> 0x0A
        #expect(w.data == Data([0x08, 0x0A]))
    }

    @Test("a float field uses wire type 5, little-endian")
    func floatField() {
        var w = ProtobufWriter()
        w.float(1, 1.0)
        // field 1, wire type 5 -> tag 0x0D; 1.0f -> 00 00 80 3F
        #expect(w.data == Data([0x0D, 0x00, 0x00, 0x80, 0x3F]))
    }

    @Test("a nested message is length-prefixed")
    func nestedMessage() {
        var w = ProtobufWriter()
        w.message(2) { inner in inner.varint(1, 1) }
        // field 2, wire type 2 -> tag 0x12; length 2; body 08 01
        #expect(w.data == Data([0x12, 0x02, 0x08, 0x01]))
    }

    @Test("varints above 127 continue into a second byte")
    func multiByteVarint() {
        var w = ProtobufWriter()
        w.varint(1, 300)
        #expect(w.data == Data([0x08, 0xAC, 0x02]))
    }
}
```

- [ ] **Step 2: Run it and confirm it fails**

```
xcodebuild test -scheme Reader -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation -only-testing:ReaderTests/AKProtobufWriterTests
```

Run this from `Packages/Features/Reader`. Expected: compile failure, `cannot find 'ProtobufWriter' in scope`.

**Confirm the suite actually ran once it compiles.** A `-only-testing:` selector that matches nothing reports success. Look for the four test names in the output before believing a pass.

- [ ] **Step 3: Implement**

```swift
import Foundation

/// A minimal protobuf encoder — just enough to write Apple's ink payload, which is a fixed shape rather than a
/// schema we compile against.
///
/// Fields must be written in ascending field-number order. Protobuf itself does not care, but Apple's payload is
/// ordered and the structural golden test pins our output against a real sample, so an out-of-order write shows up
/// as a test failure rather than as a silently rejected annotation.
struct ProtobufWriter {
    private(set) var data = Data()

    private mutating func tag(_ field: Int, _ wire: UInt8) {
        appendVarint(UInt64(field) << 3 | UInt64(wire))
    }

    private mutating func appendVarint(_ value: UInt64) {
        var v = value
        repeat {
            let byte = UInt8(v & 0x7F)
            v >>= 7
            data.append(v == 0 ? byte : byte | 0x80)
        } while v != 0
    }

    mutating func varint(_ field: Int, _ value: UInt64) {
        tag(field, 0)
        appendVarint(value)
    }

    mutating func fixed64(_ field: Int, _ value: UInt64) {
        tag(field, 1)
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }

    mutating func double(_ field: Int, _ value: Double) {
        fixed64(field, value.bitPattern)
    }

    mutating func fixed32(_ field: Int, _ value: UInt32) {
        tag(field, 5)
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }

    mutating func float(_ field: Int, _ value: Float) {
        fixed32(field, value.bitPattern)
    }

    mutating func bytes(_ field: Int, _ value: Data) {
        tag(field, 2)
        appendVarint(UInt64(value.count))
        data.append(value)
    }

    mutating func message(_ field: Int, _ body: (inout ProtobufWriter) -> Void) {
        var inner = ProtobufWriter()
        body(&inner)
        bytes(field, inner.data)
    }
}
```

- [ ] **Step 4: Run the tests and confirm they pass**

Same command. Expected: 4 tests ran, 4 passed.

- [ ] **Step 5: Commit**

```bash
git add Packages/Features/Reader/Sources/ReaderAnnotationCore/AK/ProtobufWriter.swift Packages/Features/Reader/Tests/ReaderTests/AKProtobufWriterTests.swift
git commit -m "feat(reader): a minimal protobuf writer for Apple's ink payload"
```

---

### Task 2: Gzip framing and the deflate seam

**Files:**
- Create: `Packages/Features/Reader/Sources/ReaderAnnotationCore/AK/GzipWriter.swift`
- Create: `Packages/Features/Reader/Sources/Reader/Annotation/Export/AppleDeflater.swift`
- Test: `Packages/Features/Reader/Tests/ReaderTests/AKGzipWriterTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `protocol Deflating { func deflate(_ data: Data) throws -> Data }`, `enum GzipWriter { static func gzip(_ data: Data, using: Deflating) throws -> Data }`, and `struct AppleDeflater: Deflating` in the Reader target.

Foundation has no gzip. Apple's `Compression` framework has raw DEFLATE but no framing, and does not exist on Android — so the framing lives in the shared target and only the compressor is behind a seam.

- [ ] **Step 1: Write the failing test**

```swift
import Compression
import Foundation
import Testing
@testable import Reader
@testable import ReaderAnnotationCore

@Suite("Gzip writer")
struct AKGzipWriterTests {
    /// Raw DEFLATE, so the test inflates the body itself rather than trusting a round trip through our own code.
    private func inflate(_ data: Data, into capacity: Int) -> Data {
        var out = Data(count: capacity)
        let produced = out.withUnsafeMutableBytes { dst in
            data.withUnsafeBytes { src in
                compression_decode_buffer(
                    dst.bindMemory(to: UInt8.self).baseAddress!, capacity,
                    src.bindMemory(to: UInt8.self).baseAddress!, data.count,
                    nil, COMPRESSION_ZLIB,
                )
            }
        }
        return out.prefix(produced)
    }

    @Test("the header is a gzip header with deflate and no extras")
    func header() throws {
        let out = try GzipWriter.gzip(Data([1, 2, 3]), using: AppleDeflater())
        #expect(out.prefix(4) == Data([0x1F, 0x8B, 0x08, 0x00]))
    }

    @Test("the body inflates back to the input and the trailer agrees")
    func roundTrip() throws {
        let payload = Data((0 ..< 5000).map { UInt8($0 % 251) })
        let out = try GzipWriter.gzip(payload, using: AppleDeflater())

        let body = out.dropFirst(10).dropLast(8)
        #expect(inflate(Data(body), into: payload.count * 2) == payload)

        let trailer = out.suffix(8)
        let isize = trailer.suffix(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        #expect(UInt32(littleEndian: isize) == UInt32(payload.count))
    }

    @Test("the CRC32 is the standard one")
    func crc() {
        // "123456789" has a well-known CRC32 of 0xCBF43926.
        #expect(GzipWriter.crc32(Data("123456789".utf8)) == 0xCBF4_3926)
    }
}
```

- [ ] **Step 2: Run it and confirm it fails**

```
xcodebuild test -scheme Reader -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation -only-testing:ReaderTests/AKGzipWriterTests
```

Expected: `cannot find 'GzipWriter' in scope`.

- [ ] **Step 3: Implement the shared half**

```swift
import Foundation

/// Raw DEFLATE, with no zlib or gzip framing around it.
///
/// Every platform has a deflate and none of them agree on how to reach it: iOS has `Compression`, Android's Swift
/// does not. The framing is identical everywhere, so it lives here and only this one call crosses the seam.
protocol Deflating {
    func deflate(_ data: Data) throws -> Data
}

/// Wraps raw DEFLATE in a gzip container, which is what Apple's ink payload is stored as.
enum GzipWriter {
    enum GzipError: Error { case deflateFailed }

    static func gzip(_ data: Data, using deflater: Deflating) throws -> Data {
        // Magic, CM = 8 (deflate), no flags, mtime 0, XFL 0, OS 255 (unknown). A fixed mtime keeps the output
        // reproducible, which is what lets a golden test compare bytes at all.
        var out = Data([0x1F, 0x8B, 0x08, 0x00, 0, 0, 0, 0, 0x00, 0xFF])
        out.append(try deflater.deflate(data))
        withUnsafeBytes(of: crc32(data).littleEndian) { out.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt32(truncatingIfNeeded: data.count).littleEndian) { out.append(contentsOf: $0) }
        return out
    }

    /// Bitwise CRC32, no table. The payloads are a few kilobytes, so the table is not worth the storage.
    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0 ..< 8 {
                crc = (crc >> 1) ^ (0xEDB8_8320 & ~((crc & 1) &- 1))
            }
        }
        return crc ^ 0xFFFF_FFFF
    }
}
```

- [ ] **Step 4: Implement the iOS half**

```swift
import Compression
import Foundation
import ReaderAnnotationCore

/// `Deflating` over Apple's `Compression` framework.
///
/// `COMPRESSION_ZLIB` is misnamed: it produces RAW DEFLATE, with no zlib header or Adler checksum, which is
/// exactly what a gzip container wants. Wrapping its output in a zlib header would be the bug.
struct AppleDeflater: Deflating {
    func deflate(_ data: Data) throws -> Data {
        // Deflate can expand incompressible input; the allowance covers the worst case for payloads this size.
        let capacity = data.count + data.count / 2 + 128
        var out = Data(count: capacity)
        let produced = out.withUnsafeMutableBytes { dst in
            data.withUnsafeBytes { src in
                compression_encode_buffer(
                    dst.bindMemory(to: UInt8.self).baseAddress!, capacity,
                    src.bindMemory(to: UInt8.self).baseAddress!, data.count,
                    nil, COMPRESSION_ZLIB,
                )
            }
        }
        guard produced > 0 else { throw GzipWriter.GzipError.deflateFailed }
        return out.prefix(produced)
    }
}
```

- [ ] **Step 5: Run the tests and confirm they pass**

Expected: 3 tests ran, 3 passed.

- [ ] **Step 6: Commit**

```bash
git add Packages/Features/Reader/Sources/ReaderAnnotationCore/AK/GzipWriter.swift Packages/Features/Reader/Sources/Reader/Annotation/Export/AppleDeflater.swift Packages/Features/Reader/Tests/ReaderTests/AKGzipWriterTests.swift
git commit -m "feat(reader): gzip framing shared, deflate behind a one-method seam"
```

---

### Task 3: The three-rectangle geometry

**Files:**
- Create: `Packages/Features/Reader/Sources/ReaderAnnotationCore/AK/AKInkGeometry.swift`
- Test: `Packages/Features/Reader/Tests/ReaderTests/AKInkGeometryTests.swift`

**Interfaces:**
- Consumes: `Domain.InkStroke`.
- Produces: `enum AKInkGeometry` with `static let canvasScale: CGFloat`, `static func inkBox(of strokes: [InkStroke]) -> CGRect?`, `static func canvasBox(_ inkBox: CGRect) -> CGRect`, `static func archiveRect(_ inkBox: CGRect, pageHeight: CGFloat) -> CGRect`, `static func annotationRect(_ archiveRect: CGRect) -> CGRect`, `static func drawingSize(pageSize: CGSize) -> CGSize`.

The three rectangles must agree to well under 0.1pt or the annotation is discarded in silence. They are therefore all derived from one box, and never computed separately.

- [ ] **Step 1: Write the failing test**

```swift
import CoreGraphics
import Domain
import Foundation
import Testing
@testable import ReaderAnnotationCore

@Suite("AK ink geometry")
struct AKInkGeometryTests {
    private func stroke(x: [Float], y: [Float], width: [Float]) -> InkStroke {
        InkStroke(
            tool: .pen, colorRGBA: 0xFF00_00FF, baseWidthSp: 2, opacity: 1,
            x: x, y: y, width: width, force: [], azimuth: [], altitude: [], timeMillis: [],
        )
    }

    @Test("the ink box is the point extent grown by half the widest sample plus a point")
    func inkBox() throws {
        let box = try #require(AKInkGeometry.inkBox(of: [stroke(x: [10, 30], y: [20, 40], width: [2, 4])]))
        // half of 4 = 2, plus 1 point of slack -> grow by 3 on every side
        #expect(box == CGRect(x: 7, y: 17, width: 26, height: 26))
    }

    @Test("the canvas scale cancels out of the archive rectangle")
    func scaleCancels() {
        // drawingSize is the page scaled by the same factor the box is, so sx and sy are its reciprocal and the
        // archive rectangle is the ink box with y flipped -- nothing else. This invariant is what keeps the three
        // rectangles exactly consistent instead of nearly consistent.
        let page = CGSize(width: 595, height: 842)
        let ink = CGRect(x: 100, y: 200, width: 50, height: 30)
        let size = AKInkGeometry.drawingSize(pageSize: page)
        let sx = page.width / size.width
        let sy = page.height / size.height
        let canvas = AKInkGeometry.canvasBox(ink)

        let rect = AKInkGeometry.archiveRect(ink, pageHeight: page.height)
        #expect(abs(rect.minX - canvas.minX * sx) < 0.000_01)
        #expect(abs(rect.minY - (page.height - (canvas.minY + canvas.height) * sy)) < 0.000_01)
        #expect(abs(rect.minX - ink.minX) < 0.000_01)
        #expect(abs(rect.minY - (page.height - ink.maxY)) < 0.000_01)
    }

    @Test("the annotation rectangle is the archive rectangle grown one point on every side")
    func annotationRect() {
        let archive = CGRect(x: 145.6, y: 497.5, width: 228.1, height: 8.2)
        #expect(AKInkGeometry.annotationRect(archive)
            == CGRect(x: 144.6, y: 496.5, width: 230.1, height: 10.2))
    }

    @Test("the page height must be the real MediaBox, not A4's nominal size")
    func nominalA4IsWrong() {
        // A page that is really 595 x 842 against A4's nominal 841.8898 puts the rectangle about 0.11pt out,
        // which is enough for the annotation to be rejected outright. This pins the difference so nobody
        // "tidies" the page size into a constant later.
        let ink = CGRect(x: 100, y: 200, width: 50, height: 30)
        let real = AKInkGeometry.archiveRect(ink, pageHeight: 842)
        let nominal = AKInkGeometry.archiveRect(ink, pageHeight: 841.8898)
        #expect(abs(real.minY - nominal.minY) > 0.1)
    }

    @Test("an empty stroke has no box")
    func empty() {
        #expect(AKInkGeometry.inkBox(of: [stroke(x: [], y: [], width: [])]) == nil)
    }
}
```

- [ ] **Step 2: Run it and confirm it fails**

```
xcodebuild test -scheme Reader -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation -only-testing:ReaderTests/AKInkGeometryTests
```

Expected: `cannot find 'AKInkGeometry' in scope`.

- [ ] **Step 3: Implement**

```swift
import CoreGraphics
import Domain
import Foundation

/// The rectangles Apple's ink annotation is placed by, all derived from one box.
///
/// Three of them describe the same area and must agree to well under a tenth of a point: the payload's own stored
/// bounding box, the archive's `rectangle`, and the PDF annotation's `/Rect`. A disagreement of about 0.1pt --
/// which is all it takes to use A4's nominal height against a page that is really 842 points -- makes Apple's
/// markup discard the annotation in silence. It neither erases nor selects, and only the appearance stream keeps
/// it visible, so the failure looks like nothing happening at all.
///
/// Deriving them separately cannot guarantee that. So there is one box, in page-local points with a top-left
/// origin and y down, and everything else is a function of it.
enum AKInkGeometry {
    /// Page points to canvas units. Apple's samples put a 595 x 842 page on a 792.8 x 1122.1 canvas, which is the
    /// 96-against-72 ratio screens use. Any consistent scale works -- it cancels out of the archive rectangle --
    /// so this stays with the one Apple ships rather than inventing another.
    static let canvasScale: CGFloat = 96.0 / 72.0

    static func drawingSize(pageSize: CGSize) -> CGSize {
        CGSize(width: pageSize.width * canvasScale, height: pageSize.height * canvasScale)
    }

    /// The extent of every point, grown by half the widest sample (the ink's own reach) plus a point of
    /// anti-aliasing slack. `nil` when there are no points to bound.
    static func inkBox(of strokes: [InkStroke]) -> CGRect? {
        var minX = CGFloat.greatestFiniteMagnitude, minY = CGFloat.greatestFiniteMagnitude
        var maxX = -CGFloat.greatestFiniteMagnitude, maxY = -CGFloat.greatestFiniteMagnitude
        var widest: CGFloat = 0
        var any = false
        for stroke in strokes {
            for i in stroke.x.indices where i < stroke.y.count {
                any = true
                minX = min(minX, CGFloat(stroke.x[i]))
                maxX = max(maxX, CGFloat(stroke.x[i]))
                minY = min(minY, CGFloat(stroke.y[i]))
                maxY = max(maxY, CGFloat(stroke.y[i]))
                if i < stroke.width.count { widest = max(widest, CGFloat(stroke.width[i])) }
            }
            widest = max(widest, CGFloat(stroke.baseWidthSp))
        }
        guard any else { return nil }
        let pad = widest / 2 + 1
        return CGRect(x: minX - pad, y: minY - pad, width: maxX - minX + 2 * pad, height: maxY - minY + 2 * pad)
    }

    static func canvasBox(_ inkBox: CGRect) -> CGRect {
        inkBox.applying(CGAffineTransform(scaleX: canvasScale, y: canvasScale))
    }

    /// Page space, y up. The canvas scale cancels — `sx` is the reciprocal of the scale the box was multiplied by
    /// — so this is the ink box with its y axis flipped about the page height, and the test pins that.
    static func archiveRect(_ inkBox: CGRect, pageHeight: CGFloat) -> CGRect {
        CGRect(x: inkBox.minX, y: pageHeight - inkBox.maxY, width: inkBox.width, height: inkBox.height)
    }

    /// Measured at exactly one point on every edge, across all eight samples, to four decimals. Setting `/Rect`
    /// equal to the archive rectangle instead — which is what it looks like it should be — is rejected.
    static func annotationRect(_ archiveRect: CGRect) -> CGRect {
        archiveRect.insetBy(dx: -1, dy: -1)
    }
}
```

- [ ] **Step 4: Run the tests and confirm they pass**

Expected: 5 tests ran, 5 passed.

- [ ] **Step 5: Commit**

```bash
git add Packages/Features/Reader/Sources/ReaderAnnotationCore/AK/AKInkGeometry.swift Packages/Features/Reader/Tests/ReaderTests/AKInkGeometryTests.swift
git commit -m "feat(reader): derive all three ink rectangles from one box"
```

---

### Task 4: The payload encoder

**Files:**
- Create: `Packages/Features/Reader/Sources/ReaderAnnotationCore/AK/AKInkPayloadEncoder.swift`
- Test: `Packages/Features/Reader/Tests/ReaderTests/AKInkPayloadEncoderTests.swift`

**Interfaces:**
- Consumes: `ProtobufWriter` (Task 1), `AKInkGeometry` (Task 3), `Domain.InkStroke`.
- Produces: `enum AKInkPayloadEncoder` with `static func payload(for stroke: InkStroke, inkBox: CGRect, identifiers: [Data], timestamp: Double) -> Data`. `identifiers` must hold exactly five 16-byte values, in the order `strokeA, strokeB, strokeC, pointsA, pointsB`.

Read `docs/engineering/crdt-ink-format/README.md` before this task. Every constant below was measured; none may be adjusted to make a test pass.

**The trailing pair are values, little-endian.** `0xFE54` is the bytes `54 fe`. Writing them as a byte literal reverses them, and the annotation is rejected — this exact mistake already cost a device round.

- [ ] **Step 1: Write the failing test**

```swift
import CoreGraphics
import Domain
import Foundation
import Testing
@testable import ReaderAnnotationCore

@Suite("AK ink payload encoder")
struct AKInkPayloadEncoderTests {
    private let ids = (0 ..< 5).map { Data(repeating: UInt8($0 + 1), count: 16) }

    private func stroke(width: [Float] = [2, 2], force: [Float] = [], time: [UInt16] = []) -> InkStroke {
        InkStroke(
            tool: .pen, colorRGBA: 0xFF33_22FF, baseWidthSp: 2, opacity: 1,
            x: [10, 30], y: [20, 40], width: width, force: force, azimuth: [], altitude: [], timeMillis: time,
        )
    }

    /// The 24-byte records live in field 5 of the points container, which is field 5 of the stroke, which is
    /// field 3 of the drawing, which is field 2 of the payload.
    private func records(_ payload: Data) throws -> [Data] {
        let drawing = try #require(ProtobufReaderStub.field(2, in: payload))
        let strokeBody = try #require(ProtobufReaderStub.field(3, in: drawing))
        let points = try #require(ProtobufReaderStub.field(5, in: strokeBody))
        let blob = try #require(ProtobufReaderStub.field(5, in: points))
        return stride(from: 0, to: blob.count, by: 24).map { blob[$0 ..< $0 + 24] }.map { Data($0) }
    }

    @Test("a point record carries the trailing constants in Apple's byte order")
    func trailingConstants() throws {
        let payload = AKInkPayloadEncoder.payload(
            for: stroke(), inkBox: CGRect(x: 0, y: 0, width: 40, height: 50),
            identifiers: ids, timestamp: 810_000_000,
        )
        let first = try records(payload).first!
        #expect(first[14 ..< 16] == Data([0xE8, 0x03]))  // 1000
        #expect(first[16 ..< 18] == Data([0x00, 0x00]))  // 0
        #expect(first[20 ..< 22] == Data([0xAA, 0xAA]))  // 0xAAAA
        #expect(first[22 ..< 24] == Data([0x54, 0xFE]))  // 0xFE54, little-endian
    }

    @Test("width is a tenth of a canvas unit, so a two-point pen reads about twenty-seven")
    func widthCalibration() throws {
        // Apple's thin pen measures 24-26 and its thickest 40-56 on a canvas scaled 96/72 from the page.
        let payload = AKInkPayloadEncoder.payload(
            for: stroke(width: [2, 2]), inkBox: CGRect(x: 0, y: 0, width: 40, height: 50),
            identifiers: ids, timestamp: 810_000_000,
        )
        let first = try records(payload).first!
        let width = first[12 ..< 14].withUnsafeBytes { UInt16(littleEndian: $0.loadUnaligned(as: UInt16.self)) }
        #expect(width == 27)
    }

    @Test("a stroke with no captured time gets an eight-millisecond cadence")
    func synthesizedTime() throws {
        let payload = AKInkPayloadEncoder.payload(
            for: stroke(time: []), inkBox: CGRect(x: 0, y: 0, width: 40, height: 50),
            identifiers: ids, timestamp: 810_000_000,
        )
        let second = try records(payload)[1]
        let t = second[0 ..< 4].withUnsafeBytes { Float(bitPattern: $0.loadUnaligned(as: UInt32.self)) }
        #expect(abs(t - 0.008) < 0.000_1)
    }

    @Test("point count matches the records written")
    func pointCount() throws {
        let payload = AKInkPayloadEncoder.payload(
            for: stroke(), inkBox: CGRect(x: 0, y: 0, width: 40, height: 50),
            identifiers: ids, timestamp: 810_000_000,
        )
        #expect(try records(payload).count == 2)
    }
}
```

Add the tiny reader the tests need, in the same file:

```swift
/// A read-side helper for tests only: returns the first length-delimited field with the given number.
enum ProtobufReaderStub {
    static func field(_ number: Int, in data: Data) -> Data? {
        var i = data.startIndex
        while i < data.endIndex {
            var tag: UInt64 = 0, shift: UInt64 = 0
            while i < data.endIndex {
                let b = data[i]; i += 1
                tag |= UInt64(b & 0x7F) << shift
                shift += 7
                if b & 0x80 == 0 { break }
            }
            let field = Int(tag >> 3), wire = tag & 7
            switch wire {
            case 0:
                while i < data.endIndex, data[i] & 0x80 != 0 { i += 1 }
                i += 1
            case 1: i += 8
            case 5: i += 4
            case 2:
                var length: UInt64 = 0, lshift: UInt64 = 0
                while i < data.endIndex {
                    let b = data[i]; i += 1
                    length |= UInt64(b & 0x7F) << lshift
                    lshift += 7
                    if b & 0x80 == 0 { break }
                }
                let end = i + Int(length)
                if field == number { return Data(data[i ..< end]) }
                i = end
            default: return nil
            }
        }
        return nil
    }
}
```

- [ ] **Step 2: Run it and confirm it fails**

```
xcodebuild test -scheme Reader -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation -only-testing:ReaderTests/AKInkPayloadEncoderTests
```

Expected: `cannot find 'AKInkPayloadEncoder' in scope`.

- [ ] **Step 3: Implement**

```swift
import CoreGraphics
import Domain
import Foundation

/// Encodes one `InkStroke` as the drawing payload inside Apple's `AKAnnotationV2` archive.
///
/// The measurements behind every constant are in `docs/engineering/crdt-ink-format/README.md`. The fields whose
/// meaning is still unknown are carried as one fixed set lifted from a real sample: they are not derivable, and
/// dropping them was tested on device and produced no ink, so they are not optional either. The structural golden
/// test in `AKInkGoldenTests` is what keeps them honest.
enum AKInkPayloadEncoder {
    /// Undecoded scaffolding, byte for byte, from `tools/dumpconstants.py`.
    private enum Scaffold {
        static let strokeThreeA = Data([0x08, 0x01, 0x10, 0x00, 0x18, 0x01])
        static let strokeThreeB = Data([0x08, 0x00, 0x10, 0x01, 0x18, 0x00])
        static let strokeTen = Data([0x08, 0x00, 0x10, 0x01, 0x18, 0x00])
        static let pointsOne = Data([0x08, 0x00, 0x10, 0x00, 0x18, 0x01])
        static let pointsTwo = Data([0x08, 0x00, 0x10, 0x00, 0x18, 0x00])
    }

    /// - Parameters:
    ///   - stroke: geometry already placed — page-local points, top-left origin, y down.
    ///   - inkBox: the one box from `AKInkGeometry.inkBox`, in the same space.
    ///   - identifiers: exactly five 16-byte values, all distinct, and distinct from every other annotation in
    ///     the document. AnnotationKit names a drawing by these; sharing them makes two annotations one drawing.
    ///   - timestamp: seconds since 2001-01-01 (`Date.timeIntervalSinceReferenceDate`).
    static func payload(
        for stroke: InkStroke, inkBox: CGRect, identifiers: [Data], timestamp: Double,
    ) -> Data {
        precondition(identifiers.count == 5, "the payload carries exactly five identifiers")
        precondition(identifiers.allSatisfy { $0.count == 16 }, "identifiers are 16 bytes")

        let canvas = AKInkGeometry.canvasBox(inkBox)
        let scale = AKInkGeometry.canvasScale

        var top = ProtobufWriter()
        top.varint(1, 0)
        top.message(2) { drawing in
            drawing.varint(1, 10)
            drawing.varint(2, 10)
            drawing.message(3) { s in
                s.varint(1, 10)
                s.bytes(2, identifiers[0])
                s.bytes(2, identifiers[1])
                s.bytes(3, Scaffold.strokeThreeA)
                s.bytes(3, Scaffold.strokeThreeB)
                s.message(4) { ink in
                    ink.message(1) { rgba in
                        let c = stroke.colorRGBA
                        rgba.float(1, Float((c >> 24) & 0xFF) / 255)
                        rgba.float(2, Float((c >> 16) & 0xFF) / 255)
                        rgba.float(3, Float((c >> 8) & 0xFF) / 255)
                        rgba.float(4, Float(c & 0xFF) / 255 * stroke.opacity)
                    }
                    // folino's monoline and marker have no known identifier here, so every stroke is written as
                    // the pen. Until someone edits the mark, folino's own appearance stream is what renders.
                    ink.bytes(2, Data("com.apple.ink.pen".utf8))
                    ink.varint(3, 3)
                }
                s.message(5) { p in
                    p.bytes(1, Scaffold.pointsOne)
                    p.bytes(2, Scaffold.pointsTwo)
                    p.varint(3, 0)
                    p.varint(4, UInt64(stroke.x.count))
                    p.bytes(5, records(of: stroke, scale: scale))
                    p.message(6) { box in
                        box.float(1, Float(canvas.minX))
                        box.float(2, Float(canvas.minY))
                        box.float(3, Float(canvas.width))
                        box.float(4, Float(canvas.height))
                    }
                    p.varint(9, 0)
                    p.double(11, timestamp)
                    p.bytes(13, identifiers[3])
                    p.bytes(14, identifiers[4])
                }
                s.bytes(9, identifiers[2])
                s.bytes(10, Scaffold.strokeTen)
            }
        }
        return top.data
    }

    /// One 24-byte record per point.
    ///
    /// `[14:16]` is 1000 and `[16:18]` is 0 on every point of every sample. The trailing pair are VALUES written
    /// little-endian: `0xFE54` is the bytes `54 fe`. Spelling them as a byte literal in the order the notes read
    /// them off reverses them, and the annotation is rejected outright.
    private static func records(of stroke: InkStroke, scale: CGFloat) -> Data {
        var out = Data(capacity: stroke.x.count * 24)
        for i in stroke.x.indices {
            let t = i < stroke.timeMillis.count
                ? Float(stroke.timeMillis[i]) / 1000
                : Float(i) * 0.008  // a plausible cadence when the source device gave no timing
            out.append(le(t.bitPattern))
            out.append(le(Float(CGFloat(stroke.x[i]) * scale).bitPattern))
            out.append(le(Float(CGFloat(stroke.y[i]) * scale).bitPattern))

            // A tenth of a canvas unit: Apple's thin pen measures 24-26 and its thickest 40-56.
            let pointWidth = i < stroke.width.count ? stroke.width[i] : stroke.baseWidthSp
            let width = UInt16(clamping: Int((CGFloat(pointWidth) * scale * 10).rounded()))
            // Not load-bearing: the width is what redraws, and acceptance does not depend on either. A mid value
            // stands in when the source device captured no pressure.
            let force = UInt16(clamping: Int(((i < stroke.force.count ? stroke.force[i] : 0.5) * 1000).rounded()))
            out.append(le(width))
            out.append(le(UInt16(1000)))
            out.append(le(UInt16(0)))
            out.append(le(force))
            out.append(le(UInt16(0xAAAA)))
            out.append(le(UInt16(0xFE54)))
        }
        return out
    }

    private static func le<T: FixedWidthInteger>(_ value: T) -> Data {
        withUnsafeBytes(of: value.littleEndian) { Data($0) }
    }
}
```

- [ ] **Step 4: Run the tests and confirm they pass**

Expected: 4 tests ran, 4 passed.

- [ ] **Step 5: Commit**

```bash
git add Packages/Features/Reader/Sources/ReaderAnnotationCore/AK/AKInkPayloadEncoder.swift Packages/Features/Reader/Tests/ReaderTests/AKInkPayloadEncoderTests.swift
git commit -m "feat(reader): encode an InkStroke as Apple's ink drawing payload"
```

---

### Task 5: The archive envelope

**Files:**
- Create: `Packages/Features/Reader/Sources/ReaderAnnotationCore/AK/AKInkArchive.swift`
- Test: `Packages/Features/Reader/Tests/ReaderTests/AKInkArchiveTests.swift`

**Interfaces:**
- Consumes: `GzipWriter`, `Deflating` (Task 2), `AKInkGeometry` (Task 3).
- Produces: `enum AKInkArchive` with `static func archive(payload: Data, archiveRect: CGRect, drawingSize: CGSize, uuid: UUID, deflater: Deflating) throws -> Data`.

An `NSKeyedArchiver` plist written by hand, because the object it encodes is `AKInkAnnotation2` — an AnnotationKit class we cannot link. The graph is 18 objects; see `tools/dumparchive.py` output in the format reference.

- [ ] **Step 1: Write the failing test**

```swift
import CoreGraphics
import Foundation
import Testing
@testable import Reader
@testable import ReaderAnnotationCore

@Suite("AK ink archive")
struct AKInkArchiveTests {
    private func plist(_ data: Data) throws -> [String: Any] {
        try #require(try PropertyListSerialization
            .propertyList(from: data, format: nil) as? [String: Any])
    }

    @Test("it is a keyed archive of AKInkAnnotation2")
    func classIdentity() throws {
        let data = try AKInkArchive.archive(
            payload: Data([1, 2, 3]), archiveRect: CGRect(x: 1, y: 2, width: 3, height: 4),
            drawingSize: CGSize(width: 100, height: 200), uuid: UUID(), deflater: AppleDeflater(),
        )
        let p = try plist(data)
        #expect(p["$archiver"] as? String == "NSKeyedArchiver")
        let objects = try #require(p["$objects"] as? [Any])
        let names = objects.compactMap { ($0 as? [String: Any])?["$classname"] as? String }
        #expect(names.contains("AKInkAnnotation2"))
    }

    @Test("the rectangle round-trips through the archive")
    func rectangle() throws {
        let rect = CGRect(x: 145.60262044270834, y: 497.5652598896043,
                          width: 228.1608072916667, height: 8.254427322907077)
        let data = try AKInkArchive.archive(
            payload: Data([1, 2, 3]), archiveRect: rect,
            drawingSize: CGSize(width: 792.7741935483871, height: 1122.0645161290322),
            uuid: UUID(), deflater: AppleDeflater(),
        )
        let objects = try #require(try plist(data)["$objects"] as? [Any])
        let numbers = objects.compactMap { $0 as? Double }
        // Full precision matters: a tenth of a point of drift is enough for the annotation to be discarded.
        #expect(numbers.contains { abs($0 - rect.origin.x) < 1e-12 })
        #expect(numbers.contains { abs($0 - rect.origin.y) < 1e-12 })
        #expect(numbers.contains { abs($0 - rect.width) < 1e-12 })
        #expect(numbers.contains { abs($0 - rect.height) < 1e-12 })
    }

    @Test("the drawing is stored gzipped")
    func gzipped() throws {
        let data = try AKInkArchive.archive(
            payload: Data(repeating: 7, count: 400), archiveRect: .zero,
            drawingSize: CGSize(width: 100, height: 200), uuid: UUID(), deflater: AppleDeflater(),
        )
        let objects = try #require(try plist(data)["$objects"] as? [Any])
        let blobs = objects.compactMap { $0 as? Data }.filter { $0.prefix(3) == Data([0x1F, 0x8B, 0x08]) }
        #expect(blobs.count == 1)
    }
}
```

- [ ] **Step 2: Run it and confirm it fails**

```
xcodebuild test -scheme Reader -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation -only-testing:ReaderTests/AKInkArchiveTests
```

Expected: `cannot find 'AKInkArchive' in scope`.

- [ ] **Step 3: Implement**

```swift
import CoreGraphics
import Foundation

/// The `NSKeyedArchiver` plist Apple stores its ink annotation in, written by hand.
///
/// `NSKeyedArchiver` itself cannot help: the object being encoded is `AKInkAnnotation2`, a class in the private
/// AnnotationKit framework that is absent from the iOS SDK. The archive format is public, though, and the graph
/// is small — a flat dictionary of scalars, two boxed `NSMutableDictionary` rectangles, one gzipped blob.
///
/// The scalars that are not geometry are carried verbatim from a real sample. `originalModelBaseScaleFactor` in
/// particular is not the canvas-to-page ratio and its role is unexplained; it is copied, not computed.
enum AKInkArchive {
    static func archive(
        payload: Data, archiveRect: CGRect, drawingSize: CGSize, uuid: UUID, deflater: Deflating,
    ) throws -> Data {
        let drawing = try GzipWriter.gzip(payload, using: deflater)

        // $objects is index-addressed; every UID below refers to a slot in this array, so the order is the
        // structure. Index 0 is always the "$null" placeholder.
        var objects: [Any] = ["$null"]
        func add(_ object: Any) -> [String: Any] {
            objects.append(object)
            return ["CF$UID": objects.count - 1]
        }

        let dictionaryClass = add([
            "$classname": "NSMutableDictionary",
            "$classes": ["NSMutableDictionary", "NSDictionary", "NSObject"],
        ])

        func box(_ values: KeyValuePairs<String, Double>) -> [String: Any] {
            let keys = values.map { add($0.key) }
            let numbers = values.map { add($0.value) }
            return add(["NS.keys": keys, "NS.objects": numbers, "$class": dictionaryClass])
        }

        let uuidRef = add(uuid.uuidString)
        let rectRef = box([
            "X": archiveRect.origin.x, "Y": archiveRect.origin.y,
            "Width": archiveRect.width, "Height": archiveRect.height,
        ])
        let sizeRef = box(["Width": drawingSize.width, "Height": drawingSize.height])
        let drawingRef = add(drawing)
        let rootClass = add([
            "$classname": "AKInkAnnotation2",
            "$classes": ["AKInkAnnotation2", "AKInkAnnotation", "AKAnnotation", "NSObject"],
        ])

        let root = add([
            "UUID": uuidRef,
            "rectangle": rectRef,
            "drawingSize": sizeRef,
            "drawing": drawingRef,
            "akPlat": 2,
            "akVers": 2,
            "formContentType": 0,
            "originalExifOrientation": 1,
            "originalModelBaseScaleFactor": 0.7997311827956989,
            "AKIsFormFieldKey": false,
            "editsDisableAppearanceOverride": true,
            "shouldUsePlaceholderText": true,
            "textIsClipped": false,
            "textIsFixedHeight": false,
            "textIsFixedWidth": false,
            "customPlaceholderText": ["CF$UID": 0],
            "$class": rootClass,
        ])

        return try PropertyListSerialization.data(
            fromPropertyList: [
                "$version": 100_000,
                "$archiver": "NSKeyedArchiver",
                "$top": ["root": root],
                "$objects": objects,
            ],
            format: .binary, options: 0,
        )
    }
}
```

- [ ] **Step 4: Run the tests and confirm they pass**

Expected: 3 tests ran, 3 passed. If `PropertyListSerialization` rejects the `CF$UID` dictionaries, the plist encoder needs real `CFKeyedArchiverUID` values — construct them with `CFKeyedArchiverUIDCreate` via `unsafeBitCast` to `Any`, or fall back to writing the plist with `NSKeyedArchiver`'s own `encode` of a placeholder object graph and substituting the class name. Note in the commit which route was taken.

- [ ] **Step 5: Commit**

```bash
git add Packages/Features/Reader/Sources/ReaderAnnotationCore/AK/AKInkArchive.swift Packages/Features/Reader/Tests/ReaderTests/AKInkArchiveTests.swift
git commit -m "feat(reader): hand-write the AKInkAnnotation2 keyed archive"
```

---

### Task 6: The structural golden test

**Files:**
- Create: `Packages/Features/Reader/Tests/ReaderTests/Resources/apple-ink-sample.bin`
- Create: `Packages/Features/Reader/Tests/ReaderTests/AKInkGoldenTests.swift`

**Interfaces:**
- Consumes: everything from Tasks 1-5.
- Produces: nothing; this is the regression guard.

Copy the fixture from the research directory:

```bash
cp docs/engineering/crdt-ink-format/samples/ppk-p1-1.bin \
   Packages/Features/Reader/Tests/ReaderTests/Resources/apple-ink-sample.bin
```

This is the test that matters most. Both defects in the research writer — a repeated field emitted once, and two bytes in the wrong order — were invisible to a comparison of values and fell out the moment structure was compared first. It is also the only thing standing behind the scaffolding constants nobody understands.

- [ ] **Step 1: Write the failing test**

```swift
import CoreGraphics
import Domain
import Foundation
import Testing
@testable import Reader
@testable import ReaderAnnotationCore

@Suite("AK ink structural golden")
struct AKInkGoldenTests {
    /// (field number, wire type) in order, at one nesting level.
    private func shape(_ data: Data) -> [(Int, UInt64)] {
        var out: [(Int, UInt64)] = []
        var i = data.startIndex
        while i < data.endIndex {
            var tag: UInt64 = 0, shift: UInt64 = 0
            while i < data.endIndex {
                let b = data[i]; i += 1
                tag |= UInt64(b & 0x7F) << shift
                shift += 7
                if b & 0x80 == 0 { break }
            }
            let field = Int(tag >> 3), wire = tag & 7
            out.append((field, wire))
            switch wire {
            case 0:
                while i < data.endIndex, data[i] & 0x80 != 0 { i += 1 }
                i += 1
            case 1: i += 8
            case 5: i += 4
            case 2:
                var length: UInt64 = 0, lshift: UInt64 = 0
                while i < data.endIndex {
                    let b = data[i]; i += 1
                    length |= UInt64(b & 0x7F) << lshift
                    lshift += 7
                    if b & 0x80 == 0 { break }
                }
                i += Int(length)
            default: return out
            }
        }
        return out
    }

    private func ours() -> Data {
        let stroke = InkStroke(
            tool: .pen, colorRGBA: 0xFF33_22FF, baseWidthSp: 2, opacity: 1,
            x: [10, 30, 50], y: [20, 40, 20], width: [2, 2, 2],
            force: [], azimuth: [], altitude: [], timeMillis: [],
        )
        let box = AKInkGeometry.inkBox(of: [stroke])!
        return AKInkPayloadEncoder.payload(
            for: stroke, inkBox: box,
            identifiers: (0 ..< 5).map { Data(repeating: UInt8($0 + 1), count: 16) },
            timestamp: 810_000_000,
        )
    }

    @Test("our payload has Apple's field order and wire types at every level")
    func structureMatches() throws {
        let url = try #require(Bundle.module.url(forResource: "apple-ink-sample", withExtension: "bin"))
        let apple = try AKTestSupport.drawingPayload(inArchiveAt: url)

        #expect(shape(ours()).map(\.0) == shape(apple).map(\.0))
        #expect(shape(ours()).map(\.1) == shape(apple).map(\.1))

        for level in [2] {
            let a = try #require(ProtobufReaderStub.field(level, in: apple))
            let b = try #require(ProtobufReaderStub.field(level, in: ours()))
            #expect(shape(b).map(\.0) == shape(a).map(\.0))
            #expect(shape(b).map(\.1) == shape(a).map(\.1))
        }

        let appleStroke = try #require(ProtobufReaderStub.field(3, in:
            #require(ProtobufReaderStub.field(2, in: apple))))
        let ourStroke = try #require(ProtobufReaderStub.field(3, in:
            #require(ProtobufReaderStub.field(2, in: ours()))))
        // `.2` and `.3` each occur twice on the stroke. Emitting one of a repeated field is exactly the defect
        // this comparison exists to catch, so the counts are part of the assertion.
        #expect(shape(ourStroke).map(\.0) == shape(appleStroke).map(\.0))
        #expect(shape(ourStroke).map(\.1) == shape(appleStroke).map(\.1))

        let applePoints = try #require(ProtobufReaderStub.field(5, in: appleStroke))
        let ourPoints = try #require(ProtobufReaderStub.field(5, in: ourStroke))
        #expect(shape(ourPoints).map(\.0) == shape(applePoints).map(\.0))
        #expect(shape(ourPoints).map(\.1) == shape(applePoints).map(\.1))
    }

    @Test("our point records are the same length as Apple's")
    func recordStride() throws {
        let url = try #require(Bundle.module.url(forResource: "apple-ink-sample", withExtension: "bin"))
        let apple = try AKTestSupport.drawingPayload(inArchiveAt: url)
        for payload in [apple, ours()] {
            let stroke = try #require(ProtobufReaderStub.field(3, in:
                #require(ProtobufReaderStub.field(2, in: payload))))
            let points = try #require(ProtobufReaderStub.field(5, in: stroke))
            let blob = try #require(ProtobufReaderStub.field(5, in: points))
            #expect(blob.count % 24 == 0)
        }
    }
}
```

- [ ] **Step 2: Write the fixture reader the test needs**

In the same file:

```swift
/// Pulls the gzipped drawing back out of a real Apple archive, for tests only.
enum AKTestSupport {
    enum SupportError: Error { case noDrawingInArchive }

    // `#require` belongs inside a test; this is a plain throwing helper, so it throws its own error instead.
    static func drawingPayload(inArchiveAt url: URL) throws -> Data {
        let plist = try PropertyListSerialization
            .propertyList(from: try Data(contentsOf: url), format: nil) as? [String: Any]
        let objects = (plist?["$objects"] as? [Any]) ?? []
        guard let gzip = objects.compactMap({ $0 as? Data })
            .first(where: { $0.prefix(3) == Data([0x1F, 0x8B, 0x08]) })
        else { throw SupportError.noDrawingInArchive }
        return try gunzip(gzip)
    }

    /// Strips the gzip framing and inflates the raw DEFLATE body.
    private static func gunzip(_ data: Data) throws -> Data {
        let body = data.dropFirst(10).dropLast(8)
        let size = data.suffix(4).withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)) }
        var out = Data(count: Int(size))
        let produced = out.withUnsafeMutableBytes { dst in
            Data(body).withUnsafeBytes { src in
                compression_decode_buffer(
                    dst.bindMemory(to: UInt8.self).baseAddress!, Int(size),
                    src.bindMemory(to: UInt8.self).baseAddress!, body.count,
                    nil, COMPRESSION_ZLIB,
                )
            }
        }
        return out.prefix(produced)
    }
}
```

Add `import Compression` at the top of the file.

- [ ] **Step 3: Run it**

```
xcodebuild test -scheme Reader -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation -only-testing:ReaderTests/AKInkGoldenTests
```

Expected: 2 tests ran, 2 passed. **If either fails, the encoder is wrong — do not adjust the test to match the encoder.** Compare the two shape arrays and fix `AKInkPayloadEncoder`.

- [ ] **Step 4: Commit**

```bash
git add Packages/Features/Reader/Tests/ReaderTests/Resources/apple-ink-sample.bin Packages/Features/Reader/Tests/ReaderTests/AKInkGoldenTests.swift
git commit -m "test(reader): pin our payload's structure against a real Apple sample"
```

---

### Task 7: Compose the annotation

**Files:**
- Modify: `Packages/Features/Reader/Sources/Reader/Annotation/Export/AnnotatedPDFComposer.swift`
- Test: `Packages/Features/Reader/Tests/ReaderTests/AnnotatedPDFComposerAKTests.swift`

**Interfaces:**
- Consumes: `AKInkGeometry`, `AKInkPayloadEncoder`, `AKInkArchive`, `AppleDeflater`.
- Produces: `AnnotatedPDFComposer.compose(basePDF:drawings:placements:)` returns
  `(data: Data, akEncodeFailures: Int)` instead of `Data`. Two call sites in
  `ReaderAnnotatedPDFRenderer.swift` (around lines 48 and 68) take `.data`; the renderer logs the new event when
  the count is non-zero. Existing composer tests that use the return value need `.data` added.
- Also adds `AnalyticsEvent.annotatedExportAKEncodeFailed(count:)` in
  `Packages/Domain/Sources/Domain/Analytics/AnalyticsEvent+Factories.swift`, beside `annotatedExportDrifted`.

Three changes to `makeAnnotation`:

1. **The bounds come from `AKInkGeometry.inkBox`**, computed from `InkStroke` geometry, replacing
   `placed.bounds.insetBy(dx: -1, dy: -1)`. Do **not** clip the box to the page: the three rectangles must agree
   exactly, and an intersection breaks that. Keep the existing "skip it entirely" guard for a box that does not
   intersect the page at all.
2. **A stroke is obtained as an `InkStroke`.** The stored blob is either FINK bytes or — for pixel-erased and
   legacy strokes — a `PKDrawing` archive. `InkStrokeCodec.isInkStroke(_:)` distinguishes them;
   `InkStrokePencilKitBridge.inkStroke(from:)` converts a `PKStroke` for the legacy case. A stroke carrying a
   `mask` cannot be represented and simply gets no payload.
3. **`/AAPL:AKExtras` is set** to `["AAPL:AKAnnotationV2": base64]`.

- [ ] **Step 1: Write the failing test**

```swift
import Domain
import Foundation
import PDFKit
import Testing
@testable import Reader
@testable import ReaderAnnotationCore

@MainActor
@Suite("Annotated PDF composer — Apple ink payload")
struct AnnotatedPDFComposerAKTests {
    private func onePagePDF(size: CGSize) -> Data {
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: size))
        return renderer.pdfData { context in
            context.beginPage()
            UIColor.black.setStroke()
            UIBezierPath(rect: CGRect(x: 10, y: 10, width: 100, height: 100)).stroke()
        }
    }

    private func drawing() -> DrawingAnchor {
        let stroke = InkStroke(
            tool: .pen, colorRGBA: 0xFF33_22FF, baseWidthSp: 2, opacity: 1,
            x: [10, 30, 50], y: [20, 40, 20], width: [2, 2, 2],
            force: [], azimuth: [], altitude: [], timeMillis: [],
        )
        return DrawingAnchor(
            kind: .page(PageAnchor(pageIndex: 0)),
            encodedDrawing: InkStrokeCodec.encode(stroke),
        )
    }

    @Test("every ink annotation carries an AKAnnotationV2 payload")
    func payloadAttached() throws {
        let data = try AnnotatedPDFComposer.compose(
            basePDF: onePagePDF(size: CGSize(width: 595, height: 842)),
            drawings: [drawing()],
            placements: [InkPlacement(pageIndex: 0, drawingIndex: 0,
                                      transform: StrokeTransform(sp: 1, px: 100, py: 100))],
        )
        let page = try #require(PDFDocument(data: data)?.page(at: 0))
        let annotation = try #require(page.annotations.first)
        let extras = try #require(annotation.annotationKeyValues
            .first { "\($0.key)".contains("AKExtras") }?.value as? [AnyHashable: Any])
        let base64 = try #require(extras.first { "\($0.key)".contains("AKAnnotationV2") }?.value as? String)
        #expect(Data(base64Encoded: base64)?.isEmpty == false)
    }

    @Test("no two annotations in a document share an identifier")
    func identifiersAreUnique() throws {
        let data = try AnnotatedPDFComposer.compose(
            basePDF: onePagePDF(size: CGSize(width: 595, height: 842)),
            drawings: [drawing(), drawing()],
            placements: [
                InkPlacement(pageIndex: 0, drawingIndex: 0,
                             transform: StrokeTransform(sp: 1, px: 100, py: 100)),
                InkPlacement(pageIndex: 0, drawingIndex: 1,
                             transform: StrokeTransform(sp: 1, px: 100, py: 300)),
            ],
        )
        let page = try #require(PDFDocument(data: data)?.page(at: 0))
        let payloads = page.annotations.compactMap { annotation -> String? in
            let extras = annotation.annotationKeyValues
                .first { "\($0.key)".contains("AKExtras") }?.value as? [AnyHashable: Any]
            return extras?.first { "\($0.key)".contains("AKAnnotationV2") }?.value as? String
        }
        #expect(payloads.count == 2)
        #expect(payloads[0] != payloads[1])
    }

    @Test("the annotation rectangle is the archive rectangle grown one point")
    func rectangleAgrees() throws {
        let placement = InkPlacement(pageIndex: 0, drawingIndex: 0,
                                     transform: StrokeTransform(sp: 1, px: 100, py: 100))
        let data = try AnnotatedPDFComposer.compose(
            basePDF: onePagePDF(size: CGSize(width: 595, height: 842)),
            drawings: [drawing()], placements: [placement],
        )
        let page = try #require(PDFDocument(data: data)?.page(at: 0))
        let bounds = try #require(page.annotations.first).bounds

        var stroke = try InkStrokeCodec.decode(drawing().encodedDrawing)
        stroke.x = stroke.x.map { $0 * 1 + 100 }
        stroke.y = stroke.y.map { $0 * 1 + 100 }
        let box = try #require(AKInkGeometry.inkBox(of: [stroke]))
        let expected = AKInkGeometry.annotationRect(
            AKInkGeometry.archiveRect(box, pageHeight: page.bounds(for: .mediaBox).height))
        #expect(abs(bounds.minX - expected.minX) < 0.001)
        #expect(abs(bounds.minY - expected.minY) < 0.001)
    }
}
```

- [ ] **Step 2: Run it and confirm it fails**

```
xcodebuild test -scheme Reader -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation -only-testing:ReaderTests/AnnotatedPDFComposerAKTests
```

Expected: the first two fail because no `AKExtras` key is written.

- [ ] **Step 3: Add the placed-stroke helper to the composer**

```swift
/// The placed stroke as neutral geometry, for the Apple ink payload.
///
/// The stored blob is FINK bytes for everything written since the neutral format landed, and a `PKDrawing`
/// archive for older data and for pixel-erased strokes. The archive route needs PencilKit to read, so it goes
/// through the existing bridge; a stroke carrying a `mask` cannot be expressed as an `InkStroke` at all and
/// returns nil, which costs it the payload and nothing else.
private static func placedInkStroke(_ stored: Data, transform: StrokeTransform) -> InkStroke? {
    var stroke: InkStroke
    if InkStrokeCodec.isInkStroke(stored) {
        guard let decoded = try? InkStrokeCodec.decode(stored) else { return nil }
        stroke = decoded
    } else {
        guard let drawing = try? PKDrawing(data: stored),
              let pk = drawing.strokes.first, pk.mask == nil
        else { return nil }
        stroke = InkStrokePencilKitBridge.inkStroke(from: pk)
    }
    let sp = Float(transform.sp)
    stroke.x = stroke.x.map { $0 * sp + Float(transform.px) }
    stroke.y = stroke.y.map { $0 * sp + Float(transform.py) }
    stroke.width = stroke.width.map { $0 * sp }
    stroke.baseWidthSp *= sp
    return stroke
}
```

`InkStrokePencilKitBridge.inkStroke(from:)` is currently private; widen it to `static` within the module (no
`public`).

- [ ] **Step 4: Replace the bounds derivation and attach the payload**

In `makeAnnotation`, replace the block computing `pageLocalBounds` and `annotationBounds` with:

```swift
let pageSize = page.bounds(for: .mediaBox).size

// One box, and all three rectangles derived from it. The payload's stored bounding box, the archive's
// rectangle and this annotation's /Rect must agree to well under a tenth of a point or Apple's markup discards
// the annotation in silence, and deriving them separately cannot guarantee that. Note this is deliberately NOT
// clipped to the page: an intersection would move the rectangle out from under the payload.
let inkStroke = placedInkStroke(drawings[placement.drawingIndex].encodedDrawing, transform: placement.transform)
let inkBox = inkStroke.flatMap { AKInkGeometry.inkBox(of: [$0]) }
    ?? placed.bounds.insetBy(dx: -1, dy: -1)
guard inkBox.intersects(CGRect(origin: .zero, size: pageSize)) else { return nil }

let archiveRect = AKInkGeometry.archiveRect(inkBox, pageHeight: pageSize.height)
let annotationBounds = AKInkGeometry.annotationRect(archiveRect)
```

`annotationPoint` and everything after it are unchanged — they rebase onto `annotationBounds`, whatever it is.

Then, just before `return annotation`:

```swift
if let inkStroke, let payload = akPayload(for: inkStroke, inkBox: inkBox,
                                          archiveRect: archiveRect, pageSize: pageSize) {
    annotation.setValue(
        ["AAPL:AKAnnotationV2": payload.base64EncodedString()],
        forAnnotationKey: PDFAnnotationKey(rawValue: "AAPL:AKExtras"),
    )
}
```

and add:

```swift
/// The Apple ink payload for one placed stroke, or nil if it cannot be built.
///
/// Failure here must never fail an export. A stroke without a payload is written exactly as it was before this
/// existed — an /Ink annotation with a vector appearance — so the worst case is the behaviour that shipped.
///
/// The identifiers are freshly generated for every annotation and never reused. AnnotationKit names a drawing
/// by the identifiers inside its payload rather than by the annotation holding it, so two annotations sharing
/// them are one drawing: an eraser stroke on one deletes the other, on whatever page it happens to be.
private static func akPayload(
    for stroke: InkStroke, inkBox: CGRect, archiveRect: CGRect, pageSize: CGSize,
) -> Data? {
    let identifiers = (0 ..< 5).map { _ in withUnsafeBytes(of: UUID().uuid) { Data($0) } }
    let payload = AKInkPayloadEncoder.payload(
        for: stroke, inkBox: inkBox, identifiers: identifiers,
        timestamp: Date().timeIntervalSinceReferenceDate,
    )
    do {
        return try AKInkArchive.archive(
            payload: payload, archiveRect: archiveRect,
            drawingSize: AKInkGeometry.drawingSize(pageSize: pageSize),
            uuid: UUID(), deflater: AppleDeflater(),
        )
    } catch {
        return nil
    }
}
```

The composer is a stateless `enum` with no analytics reference, and the export's existing
`annotated_export_drifted` is logged by `ReaderAnnotatedPDFRenderer`, which holds one. So the count travels back
rather than the composer reaching sideways for a dependency:

1. `compose` accumulates `akEncodeFailures` — one per placement where `akPayload` returned nil — and returns
   `(data: Data, akEncodeFailures: Int)`.
2. Add the event factory in `Packages/Domain/Sources/Domain/Analytics/AnalyticsEvent+Factories.swift`, directly
   below `annotatedExportDrifted`, in the same shape:

```swift
/// Logged when a stroke's Apple ink payload could not be built. The stroke still exports as a plain `/Ink`
/// annotation, so this is a silent capability loss rather than a failure the user sees.
public static func annotatedExportAKEncodeFailed(count: Int) -> AnalyticsEvent {
    AnalyticsEvent(name: "annotated_export_ak_encode_failed", parameters: ["count": .int(count)])
}
```

`.int(Int)` exists — `scoreCreated(template:partCount:)` in the same file uses it for `part_count`. Log the
count raw; this codebase buckets at analysis time, not at collection.

3. In `ReaderAnnotatedPDFRenderer`, both call sites take `.data`, and after each:

```swift
if result.akEncodeFailures > 0 {
    analytics.log(.annotatedExportAKEncodeFailed(count: result.akEncodeFailures))
}
```

- [ ] **Step 5: Add the parity marker**

Above `enum AnnotatedPDFComposer`:

```swift
// PARITY(android): erasable ink in exported PDFs — the AKAnnotationV2 encoder is already shared in
// ReaderAnnotationCore, but Android has no PDF export to call it from, and would need a Deflating
// implementation over zlib.
```

- [ ] **Step 6: Run the whole Reader suite**

```
xcodebuild test -scheme Reader -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation
```

Expected: every existing test still passes, plus the three new ones. **Report the counts, not "tests pass".**

`AnnotatedPDFComposerTests` and `ReaderAnnotatedPDFEndToEndTests` already exist and already exercise this
method. Expect two kinds of break, and fix them in the source of truth rather than by loosening an assertion:

- **The return type changed.** Call sites need `.data`. Mechanical.
- **An annotation's bounds may have moved.** The box now comes from `InkStroke` geometry rather than
  `PKDrawing.bounds`, and PencilKit's render bounds include padding of its own. If an existing test pins exact
  bounds, work out which box is right before changing the number — the three-rectangle rule is the constraint,
  and a test that was pinning PencilKit's padding was pinning an implementation detail.

- [ ] **Step 7: Regenerate the parity ledger and commit**

```bash
python3 Scripts/parity-report.py
git add Packages/Features/Reader docs/engineering/ios-android-parity.md
git commit -m "feat(reader): write Apple's editable ink payload onto exported annotations"
```

---

### Task 8: Verify on a device

**Files:** none.

No simulator run and no unit test can tell us AnnotationKit accepted a payload. The only oracle is the eraser on
a real device, and this export path has already produced three bugs that reproduced nowhere else.

- [ ] **Step 1: Build and install**

```
xcodebuild -project Folino.xcodeproj -scheme Folino -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation build
```

For the device build, use the IDE (plugin trust). **Install over the existing app — never uninstall.**

- [ ] **Step 2: Confirm the binary actually contains the change**

```
nm -a <app>/Reader.debug.dylib | grep -c 'AKInkPayloadEncoder'
```

Expected: non-zero. `BUILD SUCCEEDED` does not mean the edit was compiled into the artifact that got installed.

- [ ] **Step 3: Hand the verification to the user**

Ask them to: annotate a score with several marks on more than one page, in at least two colours; export the
annotated PDF; open it in Files on a **different** device; and check each of —

- the eraser removes part of a mark, not the whole annotation;
- erasing one mark leaves the others alone, including marks on other pages;
- the lasso selects and moves a mark;
- the ink looks the same before and after the first edit (this is where a wrong width shows up);
- a mark near the top of page 1 works — the page-1 band was a real bug in the export's own geometry.

- [ ] **Step 4: Record the result**

Append the outcome to `docs/engineering/crdt-ink-format/README.md` and update
`~/.claude/projects/.../memory/project_apple_ink_annotation_format.md`, whose "残=実装" line this closes.

---

## Self-Review

**Spec coverage.** Encoder in `ReaderAnnotationCore` → Tasks 1-5. One box for three rectangles → Task 3, enforced
in Task 7. Fresh identifiers per annotation → Task 4's precondition and Task 7's generator, tested in Task 7.
`/Ink` kept → Task 7 leaves the subtype alone. gzip seam → Task 2. Failure falls back to today's annotation →
Task 7. Structural golden test → Task 6. Analytics counter → Task 7. `PARITY(android)` → Task 7. Device
verification → Task 8. Size, tool identity and the copied scaffolding are accepted limits with no task.

**Placeholders.** None: every code step carries the code. Task 5 Step 4 and Task 7 Step 4 name a fallback for a
specific API risk rather than leaving it open.

**Type consistency.** `AKInkGeometry.inkBox(of:)`, `canvasBox(_:)`, `archiveRect(_:pageHeight:)`,
`annotationRect(_:)` and `drawingSize(pageSize:)` are used with those names and signatures in Tasks 4, 6 and 7.
`AKInkPayloadEncoder.payload(for:inkBox:identifiers:timestamp:)` likewise. `Deflating.deflate(_:)` is declared in
Task 2 and used in Task 5. `ProtobufReaderStub` is defined in Task 4 and reused in Task 6 — both live in the same
test target, so it is declared once.

**One risk carried deliberately.** Task 5's hand-written `CF$UID` dictionaries may not survive
`PropertyListSerialization`; the step names the fallback rather than pretending the risk is absent.
