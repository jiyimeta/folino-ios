# iOS Annotation Neutral-Format Migration — Implementation Plan (Phase 1)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Migrate iOS annotation ink storage from opaque per-stroke `PKDrawing` archives to a shared, platform-neutral `InkStroke` binary format — with **no user-visible change** — so the format is production-validated before Android adopts it and a future "share an annotated score" feature has one interchange format.

**Architecture:** Define `InkStroke` + its binary codec in **Domain** (Foundation-only). Add a **Reader** PencilKit bridge (`PKStroke ↔ InkStroke`) and swap the four encode/decode sites in `AnnotationAnchoring` / `PDFAnnotationAnchoring` to read-both (decode InkStroke **or** legacy PKDrawing) and write-neutral. Add a **Persistence** one-time migrator driven by a Reader-supplied transcode closure, wired once at app startup. The anchoring *math* is untouched; only serialization at the PencilKit⇄bytes boundary changes.

**Tech Stack:** Swift 6.3, PencilKit, GRDB (Persistence), Swift Testing (`import Testing`, `@Test`, `#expect`).

## Global Constraints

- iOS 26+, Swift 6.3. Domain is Foundation-only (no PencilKit / CoreGraphics-UI imports).
- **No user-visible change.** The annotation UX is identical; only the at-rest byte format changes.
- **Read-both is permanent.** The legacy `PKDrawing(data:)` decoder must remain forever; never remove it.
- **`InkStroke` is the final shared format.** It must be a faithful superset of the PencilKit ink types existing iOS data can contain (`.pen`, `.pencil`, `.marker`, `.monoline`, `.fountainPen`, `.watercolor`, `.crayon`). Fidelity contract: **faithful, not pixel-identical.**
- **`encodedDrawing` stays opaque `Data`** through Domain / Persistence / CloudSync — unknown bytes must round-trip untouched (never dropped/clobbered).
- New tests use **Swift Testing**. Package tests run via `xcodebuild test` on an **iPhone 17 Pro Max** simulator with `-skipPackagePluginValidation` (run from the package directory). `swift test` does not work in this repo.
- Scheme names: Domain → `Domain`; Reader → `Reader`; Infrastructure (multi-product) → `Infrastructure-Package`.
- Git: stage whole files only (no `git add -p`). Commit after each task.

## File Structure

| File | Responsibility |
|---|---|
| `Packages/Domain/Sources/Domain/Models/InkStroke.swift` (create) | The neutral stroke value type (tool, color, opacity, per-point arrays). Foundation-only. |
| `Packages/Domain/Sources/Domain/Logic/InkStrokeCodec.swift` (create) | Binary encode/decode of `InkStroke` ↔ `Data` (little-endian, magic + version) + `isInkStroke(_:)` sniffing. |
| `Packages/Features/Reader/Sources/Reader/Annotation/InkStrokePencilKitBridge.swift` (create) | `PKStroke ↔ InkStroke`; `encodeStoredDrawing`/`decodeStoredDrawing` (read-both); public `inkStrokeDataFromLegacyPKDrawing` for the migrator. |
| `Packages/Features/Reader/Sources/Reader/Annotation/AnnotationAnchoring.swift` (modify) | Swap `dataRepresentation()`/`PKDrawing(data:)` for the bridge helpers. Math unchanged. |
| `Packages/Features/Reader/Sources/Reader/Annotation/PDFAnnotationAnchoring.swift` (modify) | Same swap for `.page`-anchored drawings. |
| `Packages/Infrastructure/Sources/Persistence/AnnotationFormatMigrator.swift` (create) | One-time pass over `annotation_layers`, applying an injected `transcode` closure per drawing. |
| `App/AppBootstrap.swift` (modify) | Run the migrator once (UserDefaults flag), async, with the Reader transcode closure. |

---

### Task 1: `InkStroke` value type + binary codec (Domain)

**Files:**
- Create: `Packages/Domain/Sources/Domain/Models/InkStroke.swift`
- Create: `Packages/Domain/Sources/Domain/Logic/InkStrokeCodec.swift`
- Test: `Packages/Domain/Tests/DomainTests/InkStrokeCodecTests.swift`

**Interfaces:**
- Produces:
  - `public struct InkStroke: Hashable, Sendable` with `public enum Tool: UInt8` (`pen=0, marker=1, pencil=2, monoline=3, fountainPen=4, watercolor=5, crayon=6`); fields: `tool: Tool`, `colorRGBA: UInt32`, `baseWidthSp: Float`, `opacity: Float`, and per-point arrays `x: [Float]`, `y: [Float]`, `width: [Float]`, `force: [Float]`, `azimuth: [Float]`, `altitude: [Float]`, `timeMillis: [UInt16]` (a trailing array may be empty when the source lacked that channel).
  - `public enum InkStrokeCodec` with `static func encode(_ stroke: InkStroke) -> Data`, `static func decode(_ data: Data) throws -> InkStroke`, `static func isInkStroke(_ data: Data) -> Bool`, and `public enum InkStrokeCodecError: Error { case badMagic, truncated, unsupportedVersion }`.

- [ ] **Step 1: Write the failing test**

Create `Packages/Domain/Tests/DomainTests/InkStrokeCodecTests.swift`:

```swift
import Testing
@testable import Domain

@Suite struct InkStrokeCodecTests {
    private func sample() -> InkStroke {
        InkStroke(
            tool: .marker,
            colorRGBA: 0xFF_33_66_CC,
            baseWidthSp: 1.75,
            opacity: 0.6,
            x: [0, 0.5, 1.25],
            y: [0, -0.3, 0.9],
            width: [1.75, 1.8, 1.6],
            force: [0.2, 0.5, 0.4],
            azimuth: [],
            altitude: [],
            timeMillis: [0, 8, 17],
        )
    }

    @Test func roundTripsAllFields() throws {
        let original = sample()
        let data = InkStrokeCodec.encode(original)
        let decoded = try InkStrokeCodec.decode(data)
        #expect(decoded == original)
    }

    @Test func sniffsOwnMagic() {
        let data = InkStrokeCodec.encode(sample())
        #expect(InkStrokeCodec.isInkStroke(data))
    }

    @Test func rejectsForeignBytes() {
        // A PKDrawing archive begins with a NSKeyedArchiver "bplist" signature, never the InkStroke magic.
        let foreign = Data("bplist00foobar".utf8)
        #expect(!InkStrokeCodec.isInkStroke(foreign))
        #expect(throws: InkStrokeCodec.InkStrokeCodecError.self) { try InkStrokeCodec.decode(foreign) }
    }

    @Test func handlesEmptyOptionalChannels() throws {
        var s = sample()
        s = InkStroke(
            tool: .pen, colorRGBA: 0xFF_00_00_00, baseWidthSp: 1, opacity: 1,
            x: [0, 1], y: [0, 1], width: [1, 1], force: [], azimuth: [], altitude: [], timeMillis: [],
        )
        let decoded = try InkStrokeCodec.decode(InkStrokeCodec.encode(s))
        #expect(decoded == s)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run (from `Packages/Domain`):
```bash
xcodebuild test -scheme Domain \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' \
  -skipPackagePluginValidation \
  -only-testing:DomainTests/InkStrokeCodecTests
```
Expected: FAIL — `cannot find 'InkStroke' in scope`.

- [ ] **Step 3: Write the model**

Create `Packages/Domain/Sources/Domain/Models/InkStroke.swift`:

```swift
import Foundation

/// A single free-hand stroke in a platform-neutral, engine-agnostic form. Geometry is stored anchor-relative in
/// staff-space (sp) units — the same baked coordinate space iOS previously stored a normalized `PKDrawing` in. This is
/// the shared on-disk stroke representation for both iOS (PencilKit) and Android (androidx.ink); each platform bridges
/// its native stroke to/from this type. Cross-rendered ink is faithful, not pixel-identical.
public struct InkStroke: Hashable, Sendable {
    /// Superset of the PencilKit ink types existing iOS data can contain, so migration is non-lossy.
    public enum Tool: UInt8, Hashable, Sendable {
        case pen = 0
        case marker = 1 // highlighter
        case pencil = 2
        case monoline = 3
        case fountainPen = 4
        case watercolor = 5
        case crayon = 6
    }

    public var tool: Tool
    /// Canonical light-appearance sRGB, 0xRRGGBBAA packed. Each platform applies its own dark-mode adaptation.
    public var colorRGBA: UInt32
    /// Nominal brush width in sp.
    public var baseWidthSp: Float
    /// Stroke opacity, 0…1.
    public var opacity: Float

    // Structure-of-arrays; all present arrays share `count`. `force`/`azimuth`/`altitude`/`timeMillis` may be empty
    // when the source device didn't provide that channel.
    public var x: [Float]
    public var y: [Float]
    public var width: [Float]
    public var force: [Float]
    public var azimuth: [Float]
    public var altitude: [Float]
    public var timeMillis: [UInt16]

    public init(
        tool: Tool, colorRGBA: UInt32, baseWidthSp: Float, opacity: Float,
        x: [Float], y: [Float], width: [Float],
        force: [Float], azimuth: [Float], altitude: [Float], timeMillis: [UInt16],
    ) {
        self.tool = tool
        self.colorRGBA = colorRGBA
        self.baseWidthSp = baseWidthSp
        self.opacity = opacity
        self.x = x
        self.y = y
        self.width = width
        self.force = force
        self.azimuth = azimuth
        self.altitude = altitude
        self.timeMillis = timeMillis
    }
}
```

- [ ] **Step 4: Write the codec**

Create `Packages/Domain/Sources/Domain/Logic/InkStrokeCodec.swift`:

```swift
import Foundation

/// Little-endian binary codec for `InkStroke`. Layout:
///   magic  "FINK"           (4 bytes, 0x46 0x49 0x4E 0x4B)
///   version u8              (= 1)
///   tool    u8
///   flags   u8             (bit0 hasForce, bit1 hasTilt (azimuth+altitude), bit2 hasTime)
///   reserved u8            (= 0)
///   colorRGBA u32
///   baseWidthSp f32
///   opacity  f32
///   count    u32
///   x[count] f32, y[count] f32, width[count] f32
///   force[count] f32       (only if hasForce)
///   azimuth[count] f32, altitude[count] f32   (only if hasTilt)
///   timeMillis[count] u16  (only if hasTime)
public enum InkStrokeCodec {
    public enum InkStrokeCodecError: Error, Equatable {
        case badMagic
        case truncated
        case unsupportedVersion
    }

    private static let magic: [UInt8] = [0x46, 0x49, 0x4E, 0x4B] // "FINK"
    private static let version: UInt8 = 1

    public static func isInkStroke(_ data: Data) -> Bool {
        data.count >= 4 && Array(data.prefix(4)) == magic
    }

    public static func encode(_ s: InkStroke) -> Data {
        let count = UInt32(s.x.count)
        let hasForce = !s.force.isEmpty
        let hasTilt = !s.azimuth.isEmpty && !s.altitude.isEmpty
        let hasTime = !s.timeMillis.isEmpty
        var flags: UInt8 = 0
        if hasForce { flags |= 0b001 }
        if hasTilt { flags |= 0b010 }
        if hasTime { flags |= 0b100 }

        var out = Data()
        out.append(contentsOf: magic)
        out.append(version)
        out.append(s.tool.rawValue)
        out.append(flags)
        out.append(0) // reserved
        appendLE(&out, s.colorRGBA)
        appendLE(&out, s.baseWidthSp.bitPattern)
        appendLE(&out, s.opacity.bitPattern)
        appendLE(&out, count)
        for v in s.x { appendLE(&out, v.bitPattern) }
        for v in s.y { appendLE(&out, v.bitPattern) }
        for v in s.width { appendLE(&out, v.bitPattern) }
        if hasForce { for v in s.force { appendLE(&out, v.bitPattern) } }
        if hasTilt {
            for v in s.azimuth { appendLE(&out, v.bitPattern) }
            for v in s.altitude { appendLE(&out, v.bitPattern) }
        }
        if hasTime { for v in s.timeMillis { appendLE(&out, v) } }
        return out
    }

    public static func decode(_ data: Data) throws -> InkStroke {
        guard isInkStroke(data) else { throw InkStrokeCodecError.badMagic }
        var r = Reader(data)
        r.skip(4) // magic
        guard try r.u8() == version else { throw InkStrokeCodecError.unsupportedVersion }
        let tool = InkStroke.Tool(rawValue: try r.u8()) ?? .pen
        let flags = try r.u8()
        r.skip(1) // reserved
        let color = try r.u32()
        let baseWidth = Float(bitPattern: try r.u32())
        let opacity = Float(bitPattern: try r.u32())
        let count = Int(try r.u32())
        let hasForce = flags & 0b001 != 0
        let hasTilt = flags & 0b010 != 0
        let hasTime = flags & 0b100 != 0

        func floats(_ n: Int) throws -> [Float] {
            var a = [Float](); a.reserveCapacity(n)
            for _ in 0..<n { a.append(Float(bitPattern: try r.u32())) }
            return a
        }
        let x = try floats(count)
        let y = try floats(count)
        let width = try floats(count)
        let force = hasForce ? try floats(count) : []
        let azimuth = hasTilt ? try floats(count) : []
        let altitude = hasTilt ? try floats(count) : []
        var time: [UInt16] = []
        if hasTime { time.reserveCapacity(count); for _ in 0..<count { time.append(try r.u16()) } }

        return InkStroke(
            tool: tool, colorRGBA: color, baseWidthSp: baseWidth, opacity: opacity,
            x: x, y: y, width: width, force: force, azimuth: azimuth, altitude: altitude, timeMillis: time,
        )
    }

    // MARK: - LE helpers

    private static func appendLE(_ d: inout Data, _ v: UInt16) {
        withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) }
    }
    private static func appendLE(_ d: inout Data, _ v: UInt32) {
        withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) }
    }

    private struct Reader {
        let data: Data
        var offset: Int
        init(_ data: Data) { self.data = data; offset = data.startIndex }
        mutating func skip(_ n: Int) { offset += n }
        mutating func u8() throws -> UInt8 {
            guard offset + 1 <= data.endIndex else { throw InkStrokeCodecError.truncated }
            defer { offset += 1 }
            return data[offset]
        }
        mutating func u16() throws -> UInt16 {
            guard offset + 2 <= data.endIndex else { throw InkStrokeCodecError.truncated }
            defer { offset += 2 }
            return UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
        }
        mutating func u32() throws -> UInt32 {
            guard offset + 4 <= data.endIndex else { throw InkStrokeCodecError.truncated }
            defer { offset += 4 }
            return UInt32(data[offset])
                | (UInt32(data[offset + 1]) << 8)
                | (UInt32(data[offset + 2]) << 16)
                | (UInt32(data[offset + 3]) << 24)
        }
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run (from `Packages/Domain`):
```bash
xcodebuild test -scheme Domain \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' \
  -skipPackagePluginValidation \
  -only-testing:DomainTests/InkStrokeCodecTests
```
Expected: PASS (4 tests).

- [ ] **Step 6: Commit**

```bash
git add Packages/Domain/Sources/Domain/Models/InkStroke.swift \
        Packages/Domain/Sources/Domain/Logic/InkStrokeCodec.swift \
        Packages/Domain/Tests/DomainTests/InkStrokeCodecTests.swift
git commit -m "feat(domain): add neutral InkStroke format + binary codec"
```

---

### Task 2: PencilKit bridge `PKStroke ↔ InkStroke` (Reader)

**Files:**
- Create: `Packages/Features/Reader/Sources/Reader/Annotation/InkStrokePencilKitBridge.swift`
- Test: `Packages/Features/Reader/Tests/ReaderTests/InkStrokePencilKitBridgeTests.swift`

**Interfaces:**
- Consumes: `InkStroke`, `InkStrokeCodec` (Task 1).
- Produces (all in `enum InkStrokePencilKitBridge`):
  - `static func inkStroke(from stroke: PKStroke) -> InkStroke`
  - `static func pkStroke(from ink: InkStroke) -> PKStroke`
  - `static func encodeStoredDrawing(_ drawing: PKDrawing) -> Data` — a **baked single-stroke** drawing → `InkStroke` bytes. Falls back to `drawing.dataRepresentation()` only if the drawing has no strokes.
  - `static func decodeStoredDrawing(_ data: Data) -> PKDrawing?` — **read-both**: InkStroke bytes → `PKDrawing`, else legacy `PKDrawing(data:)`.
  - `public static func inkStrokeDataFromLegacyPKDrawing(_ data: Data) -> Data?` — for the migrator: legacy PKDrawing bytes → InkStroke bytes; `nil` if already InkStroke or undecodable.

- [ ] **Step 1: Write the failing test**

Create `Packages/Features/Reader/Tests/ReaderTests/InkStrokePencilKitBridgeTests.swift`:

```swift
import Domain
import PencilKit
import Testing
@testable import Reader

@Suite struct InkStrokePencilKitBridgeTests {
    private func stroke(inkType: PKInkType, color: UIColor) -> PKStroke {
        let pts = [
            PKStrokePoint(location: CGPoint(x: 0, y: 0), timeOffset: 0, size: CGSize(width: 2, height: 2),
                          opacity: 1, force: 0.3, azimuth: 0, altitude: .pi / 2),
            PKStrokePoint(location: CGPoint(x: 1, y: 0.5), timeOffset: 0.008, size: CGSize(width: 2, height: 2),
                          opacity: 1, force: 0.6, azimuth: 0, altitude: .pi / 2),
            PKStrokePoint(location: CGPoint(x: 2, y: -0.4), timeOffset: 0.016, size: CGSize(width: 2, height: 2),
                          opacity: 1, force: 0.5, azimuth: 0, altitude: .pi / 2),
        ]
        let path = PKStrokePath(controlPoints: pts, creationDate: Date(timeIntervalSince1970: 0))
        return PKStroke(ink: PKInk(inkType, color: color), path: path)
    }

    @Test func highlighterRoundTripsShapeAndTool() {
        let original = stroke(inkType: .marker, color: .systemBlue)
        let ink = InkStrokePencilKitBridge.inkStroke(from: original)
        #expect(ink.tool == .marker)
        let rebuilt = InkStrokePencilKitBridge.pkStroke(from: ink)
        // Faithful, not pixel-identical: endpoints within a small sp tolerance.
        let a = rebuilt.path.interpolatedPoints(by: .distance(0.5)).map(\.location)
        #expect(abs(a.first!.x - 0) < 0.2)
        #expect(abs(a.last!.x - 2) < 0.2)
        #expect(rebuilt.ink.inkType == .marker)
    }

    @Test func penRoundTripsColor() {
        let original = stroke(inkType: .pen, color: UIColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        let ink = InkStrokePencilKitBridge.inkStroke(from: original)
        let rebuilt = InkStrokePencilKitBridge.pkStroke(from: ink)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, alpha: CGFloat = 0
        rebuilt.ink.color.getRed(&r, green: &g, blue: &b, alpha: &alpha)
        #expect(abs(r - 0.2) < 0.02)
        #expect(abs(g - 0.4) < 0.02)
        #expect(abs(b - 0.8) < 0.02)
    }

    @Test func encodeProducesInkStrokeBytes() {
        let drawing = PKDrawing(strokes: [stroke(inkType: .pen, color: .black)])
        let data = InkStrokePencilKitBridge.encodeStoredDrawing(drawing)
        #expect(InkStrokeCodec.isInkStroke(data))
    }

    @Test func decodeReadsBothFormats() {
        let drawing = PKDrawing(strokes: [stroke(inkType: .pen, color: .black)])
        let neutral = InkStrokePencilKitBridge.encodeStoredDrawing(drawing)
        let legacy = drawing.dataRepresentation()
        #expect(InkStrokePencilKitBridge.decodeStoredDrawing(neutral) != nil)
        #expect(InkStrokePencilKitBridge.decodeStoredDrawing(legacy) != nil)
    }

    @Test func migratorTranscodesLegacyOnly() {
        let drawing = PKDrawing(strokes: [stroke(inkType: .pen, color: .black)])
        let legacy = drawing.dataRepresentation()
        let neutral = InkStrokePencilKitBridge.encodeStoredDrawing(drawing)
        let transcoded = InkStrokePencilKitBridge.inkStrokeDataFromLegacyPKDrawing(legacy)
        #expect(transcoded != nil)
        #expect(InkStrokeCodec.isInkStroke(transcoded!))
        // Already-neutral input is left alone.
        #expect(InkStrokePencilKitBridge.inkStrokeDataFromLegacyPKDrawing(neutral) == nil)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run (from `Packages/Features/Reader`):
```bash
xcodebuild test -scheme Reader \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' \
  -skipPackagePluginValidation \
  -only-testing:ReaderTests/InkStrokePencilKitBridgeTests
```
Expected: FAIL — `cannot find 'InkStrokePencilKitBridge' in scope`.

- [ ] **Step 3: Write the bridge**

Create `Packages/Features/Reader/Sources/Reader/Annotation/InkStrokePencilKitBridge.swift`:

```swift
import Domain
import PencilKit
import UIKit

/// Bridges a single baked `PKStroke` (geometry already in anchor-relative sp) to/from the neutral `InkStroke`, and the
/// stored-blob helpers the anchoring + migrator use. Geometry is stored as dense on-curve samples (~`sampleSpacingSp`
/// apart) so the format re-ingests convergently into either engine's smoothing — faithful, not pixel-identical.
enum InkStrokePencilKitBridge {
    /// Sample spacing in sp for dense interpolation. Small enough that reconstruction is visually exact; tune if needed.
    private static let sampleSpacingSp: CGFloat = 0.5

    static func inkStroke(from stroke: PKStroke) -> InkStroke {
        let samples = Array(stroke.path.interpolatedPoints(by: .distance(sampleSpacingSp)))
        let points = samples.isEmpty ? Array(stroke.path) : samples

        var x = [Float](); var y = [Float](); var width = [Float]()
        var force = [Float](); var azimuth = [Float](); var altitude = [Float](); var time = [UInt16]()
        x.reserveCapacity(points.count); y.reserveCapacity(points.count); width.reserveCapacity(points.count)
        for p in points {
            x.append(Float(p.location.x))
            y.append(Float(p.location.y))
            width.append(Float(p.size.width))
            force.append(Float(p.force))
            azimuth.append(Float(p.azimuth))
            altitude.append(Float(p.altitude))
            time.append(UInt16(clamping: Int((p.timeOffset * 1000).rounded())))
        }

        return InkStroke(
            tool: tool(from: stroke.ink.inkType),
            colorRGBA: rgba(from: stroke.ink.color),
            baseWidthSp: Float(nominalWidth(of: stroke)),
            opacity: 1,
            x: x, y: y, width: width, force: force, azimuth: azimuth, altitude: altitude, timeMillis: time,
        )
    }

    static func pkStroke(from ink: InkStroke) -> PKStroke {
        let n = ink.x.count
        var points = [PKStrokePoint]()
        points.reserveCapacity(n)
        for i in 0..<n {
            let w = i < ink.width.count ? CGFloat(ink.width[i]) : CGFloat(ink.baseWidthSp)
            let f = i < ink.force.count ? CGFloat(ink.force[i]) : 1
            let az = i < ink.azimuth.count ? CGFloat(ink.azimuth[i]) : 0
            let al = i < ink.altitude.count ? CGFloat(ink.altitude[i]) : .pi / 2
            let t = i < ink.timeMillis.count ? Double(ink.timeMillis[i]) / 1000 : 0
            points.append(PKStrokePoint(
                location: CGPoint(x: CGFloat(ink.x[i]), y: CGFloat(ink.y[i])),
                timeOffset: t, size: CGSize(width: w, height: w),
                opacity: CGFloat(ink.opacity), force: f, azimuth: az, altitude: al,
            ))
        }
        let path = PKStrokePath(controlPoints: points, creationDate: Date(timeIntervalSince1970: 0))
        return PKStroke(ink: PKInk(inkType(from: ink.tool), color: color(from: ink.colorRGBA)), path: path)
    }

    // MARK: - Stored-blob helpers (the PencilKit⇄bytes boundary)

    static func encodeStoredDrawing(_ drawing: PKDrawing) -> Data {
        guard let stroke = drawing.strokes.first else { return drawing.dataRepresentation() }
        return InkStrokeCodec.encode(inkStroke(from: stroke))
    }

    static func decodeStoredDrawing(_ data: Data) -> PKDrawing? {
        if InkStrokeCodec.isInkStroke(data) {
            guard let ink = try? InkStrokeCodec.decode(data) else { return nil }
            return PKDrawing(strokes: [pkStroke(from: ink)])
        }
        return try? PKDrawing(data: data)
    }

    static func inkStrokeDataFromLegacyPKDrawing(_ data: Data) -> Data? {
        guard !InkStrokeCodec.isInkStroke(data) else { return nil }
        guard let drawing = try? PKDrawing(data: data) else { return nil }
        return encodeStoredDrawing(drawing)
    }

    // MARK: - Ink-type & color mapping

    private static func tool(from t: PKInkType) -> InkStroke.Tool {
        switch t {
        case .pen: .pen
        case .marker: .marker
        case .pencil: .pencil
        case .monoline: .monoline
        case .fountainPen: .fountainPen
        case .watercolor: .watercolor
        case .crayon: .crayon
        @unknown default: .pen
        }
    }

    private static func inkType(from tool: InkStroke.Tool) -> PKInkType {
        switch tool {
        case .pen: .pen
        case .marker: .marker
        case .pencil: .pencil
        case .monoline: .monoline
        case .fountainPen: .fountainPen
        case .watercolor: .watercolor
        case .crayon: .crayon
        }
    }

    private static func nominalWidth(of stroke: PKStroke) -> CGFloat {
        stroke.path.first?.size.width ?? 1
    }

    private static func rgba(from color: UIColor) -> UInt32 {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        let resolved = color.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))
        resolved.getRed(&r, green: &g, blue: &b, alpha: &a)
        func c(_ v: CGFloat) -> UInt32 { UInt32((max(0, min(1, v)) * 255).rounded()) }
        return (c(r) << 24) | (c(g) << 16) | (c(b) << 8) | c(a)
    }

    private static func color(from rgba: UInt32) -> UIColor {
        UIColor(
            red: CGFloat((rgba >> 24) & 0xFF) / 255,
            green: CGFloat((rgba >> 16) & 0xFF) / 255,
            blue: CGFloat((rgba >> 8) & 0xFF) / 255,
            alpha: CGFloat(rgba & 0xFF) / 255,
        )
    }
}
```

> **Executor note:** verify the `PKStrokePoint` initializer arity and `interpolatedPoints(by:)` against the installed
> SDK — if the SDK exposes a `secondaryScale`/additional trailing parameter, use the default. `PKStrokePath` is a
> `RandomAccessCollection` of `PKStrokePoint`, so `Array(stroke.path)` yields its control points.

- [ ] **Step 4: Run tests to verify they pass**

Run (from `Packages/Features/Reader`):
```bash
xcodebuild test -scheme Reader \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' \
  -skipPackagePluginValidation \
  -only-testing:ReaderTests/InkStrokePencilKitBridgeTests
```
Expected: PASS (5 tests). If the shape tolerance fails, halve `sampleSpacingSp` and re-run.

- [ ] **Step 5: Commit**

```bash
git add Packages/Features/Reader/Sources/Reader/Annotation/InkStrokePencilKitBridge.swift \
        Packages/Features/Reader/Tests/ReaderTests/InkStrokePencilKitBridgeTests.swift
git commit -m "feat(reader): add PKStroke <-> InkStroke bridge with read-both helpers"
```

---

### Task 3: Swap `AnnotationAnchoring` / `PDFAnnotationAnchoring` to write-neutral + read-both

**Files:**
- Modify: `Packages/Features/Reader/Sources/Reader/Annotation/AnnotationAnchoring.swift` (lines 64-66, 101, 122-124, 135)
- Modify: `Packages/Features/Reader/Sources/Reader/Annotation/PDFAnnotationAnchoring.swift` (its `dataRepresentation()` / `PKDrawing(data:)` sites)
- Test: `Packages/Features/Reader/Tests/ReaderTests/AnnotationAnchoringFormatTests.swift`

**Interfaces:**
- Consumes: `InkStrokePencilKitBridge.encodeStoredDrawing` / `.decodeStoredDrawing` (Task 2).
- Produces: no signature change — `capture`/`capturePaged` now emit InkStroke bytes; `display`/`displayPaged` read either format. Math unchanged.

- [ ] **Step 1: Write the failing test**

Create `Packages/Features/Reader/Tests/ReaderTests/AnnotationAnchoringFormatTests.swift`. Mirror the fixture from the existing `AnnotationAnchoringTests.swift`: the `LayoutTestSupport.installed` line (installs the CoreText FontMetrics provider — LayoutEngine's precondition crashes without it) and the `doc(...)` builder. Place the stroke at a resolved reference point so `capture` succeeds.

```swift
import CoreGraphics
import Domain
import PencilKit
@testable import Reader
import SheetMusicCore
import SheetMusicLayout
import Testing

@Suite("AnnotationAnchoring format")
struct AnnotationAnchoringFormatTests {
    private let _install: Void = LayoutTestSupport.installed

    private func doc(staffSize: CGFloat = 28) -> LayoutDocument {
        let note = Note(pitch: 60, tpc: 14)
        let chord = Chord(duration: .whole, notes: [note])
        let measure = Measure(voices: [Voice(elements: [.chord(chord)])])
        let staff = Staff(measures: [measure, measure])
        let score = Score(division: 480, parts: [Part(id: "1", instrument: Instrument(id: "x"), staves: [staff])])
        var options = ScoreViewOptions()
        options.staffSize = staffSize
        return LayoutEngine.layout(score: score, options: options, availableWidth: 800)
    }

    private func strokeNear(_ p: CGPoint) -> PKStroke {
        let pts = (0..<5).map { i in
            PKStrokePoint(location: CGPoint(x: p.x + CGFloat(i), y: p.y), timeOffset: Double(i) * 0.01,
                          size: CGSize(width: 2, height: 2), opacity: 1, force: 0.5, azimuth: 0, altitude: .pi / 2)
        }
        return PKStroke(ink: PKInk(.pen, color: .black),
                        path: PKStrokePath(controlPoints: pts, creationDate: Date(timeIntervalSince1970: 0)))
    }

    @Test func captureEmitsNeutralBytes() throws {
        let d = doc()
        let ref = try #require(
            d.anchorReferencePoint(measureIndex: 0, tickInMeasure: 0, partIndex: 0, staffIndexInPart: 0),
        )
        let anchors = AnnotationAnchoring.capture(strokes: [strokeNear(ref.point)], in: d)
        #expect(anchors.count == 1)
        #expect(InkStrokeCodec.isInkStroke(anchors[0].encodedDrawing))
    }

    @Test func displayReadsBothFormats() throws {
        let d = doc()
        let ref = try #require(
            d.anchorReferencePoint(measureIndex: 0, tickInMeasure: 0, partIndex: 0, staffIndexInPart: 0),
        )
        let neutralAnchors = AnnotationAnchoring.capture(strokes: [strokeNear(ref.point)], in: d)
        #expect(!neutralAnchors.isEmpty)
        #expect(!AnnotationAnchoring.display(neutralAnchors, in: d).strokes.isEmpty)

        // The same anchor re-encoded in the legacy PKDrawing format also renders (read-both).
        let legacy = neutralAnchors.map { anchor -> DrawingAnchor in
            let pk = InkStrokePencilKitBridge.decodeStoredDrawing(anchor.encodedDrawing)!
            return DrawingAnchor(id: anchor.id, kind: anchor.kind, encodedDrawing: pk.dataRepresentation())
        }
        #expect(!AnnotationAnchoring.display(legacy, in: d).strokes.isEmpty)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run (from `Packages/Features/Reader`):
```bash
xcodebuild test -scheme Reader \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' \
  -skipPackagePluginValidation \
  -only-testing:ReaderTests/AnnotationAnchoringFormatTests
```
Expected: FAIL — `captureEmitsNeutralBytes` fails (`isInkStroke` is false; capture still writes `dataRepresentation()`).

- [ ] **Step 3: Swap the encode sites**

In `AnnotationAnchoring.swift`, replace the two capture encode lines. `capture` (around line 64-66):

```swift
            var normalized = PKDrawing(strokes: [stroke])
            normalized.transform(using: normalize)
            return DrawingAnchor(kind: .musical(anchor),
                                 encodedDrawing: InkStrokePencilKitBridge.encodeStoredDrawing(normalized))
```

`capturePaged` (around line 122-124):

```swift
            var normalized = PKDrawing(strokes: [docStroke])
            normalized.transform(using: normalize)
            return DrawingAnchor(kind: .musical(anchor),
                                 encodedDrawing: InkStrokePencilKitBridge.encodeStoredDrawing(normalized))
```

- [ ] **Step 4: Swap the decode sites**

In `AnnotationAnchoring.swift`, `display` (line 135):

```swift
            guard var stored = InkStrokePencilKitBridge.decodeStoredDrawing(drawing.encodedDrawing) else { continue }
```

and `displayPaged` (line 101):

```swift
                  var stored = InkStrokePencilKitBridge.decodeStoredDrawing(drawing.encodedDrawing)
```

(Note: `displayPaged` uses this inside a `guard` with `let`/`var` bindings — keep it as `var stored = ...` returning `PKDrawing?`, dropping the `try?`.)

- [ ] **Step 5: Apply the same swap to `PDFAnnotationAnchoring.swift`**

`PDFAnnotationAnchoring.swift` has the identical pattern at four sites — swap them mechanically, touching no anchoring/transform math:
- Line 57 (`capturePage`) and line 112 (`capture`): replace `normalized.dataRepresentation()` with `InkStrokePencilKitBridge.encodeStoredDrawing(normalized)`.
- Line 67 (`display`) and line 96 (`displayPage`): replace `try? PKDrawing(data: drawing.encodedDrawing)` with `InkStrokePencilKitBridge.decodeStoredDrawing(drawing.encodedDrawing)` (drop the `try?` — `decodeStoredDrawing` already returns `PKDrawing?`).

- [ ] **Step 6: Run tests to verify they pass**

Run (from `Packages/Features/Reader`):
```bash
xcodebuild test -scheme Reader \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' \
  -skipPackagePluginValidation \
  -only-testing:ReaderTests/AnnotationAnchoringFormatTests
```
Expected: PASS (2 tests). Also run the whole existing anchoring suite to confirm no regression:
```bash
xcodebuild test -scheme Reader \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' \
  -skipPackagePluginValidation \
  -only-testing:ReaderTests
```
Expected: PASS (existing anchoring round-trip tests still green — capture→display at the same layout stays exact).

- [ ] **Step 7: Commit**

```bash
git add Packages/Features/Reader/Sources/Reader/Annotation/AnnotationAnchoring.swift \
        Packages/Features/Reader/Sources/Reader/Annotation/PDFAnnotationAnchoring.swift \
        Packages/Features/Reader/Tests/ReaderTests/AnnotationAnchoringFormatTests.swift
git commit -m "feat(reader): write neutral ink, read both formats at the anchoring boundary"
```

---

### Task 4: One-time format migration (Persistence migrator + App wiring)

**Files:**
- Create: `Packages/Infrastructure/Sources/Persistence/AnnotationFormatMigrator.swift`
- Modify: `App/AppBootstrap.swift` (around line 70-95, after `annotationStore` is created)
- Test: `Packages/Infrastructure/Tests/InfrastructureTests/AnnotationFormatMigratorTests.swift`

**Interfaces:**
- Consumes: `AppDatabase`, `AnnotationLayerRecord` (Persistence); `InkStrokePencilKitBridge.inkStrokeDataFromLegacyPKDrawing` (Reader, via an injected closure — Persistence must not import PencilKit).
- Produces: `public struct AnnotationFormatMigrator` with `public init(database: AppDatabase)` and `public func migrate(transcode: @Sendable (Data) -> Data?) async throws -> Int` (returns number of layers rewritten). `transcode` returns neutral bytes for a legacy drawing, or `nil` to leave the drawing unchanged.

- [ ] **Step 1: Write the failing test**

Create `Packages/Infrastructure/Tests/InfrastructureTests/Persistence/AnnotationFormatMigratorTests.swift`. Mirror `LiveAnnotationStoreTests`: the `makeDatabase() -> (AppDatabase, TempDirectory)` temp-file helper and `insertScore(...)` (the `annotation_layers.score_item_id` foreign key requires a `score_items` row to exist first). The fake transcode is an inline `@Sendable` closure (avoids `@Sendable` capture issues from a `@MainActor` instance method).

```swift
@testable import Domain
import Foundation
import GRDB
@testable import Persistence
import Testing

@MainActor
struct AnnotationFormatMigratorTests {
    private func makeDatabase() throws -> (AppDatabase, TempDirectory) {
        let tmp = try TempDirectory()
        let db = try AppDatabase(databaseURL: tmp.url.appending(path: "f.sqlite"))
        return (db, tmp)
    }

    private func insertScore(_ db: AppDatabase, id: ScoreItemID) async throws {
        try await db.pool.write { db in
            try db.execute(
                sql: """
                INSERT INTO score_items (id, title, local_file_name, content_hash,
                    size_bytes, length_beats, default_tempo_bpm, added_at)
                VALUES (?, 'T', 'f.mscx', 'h', 0, 0, 120, 0)
                """,
                arguments: [id.rawValue.uuidString],
            )
        }
    }

    @Test func rewritesLegacyDrawingsAndIsIdempotent() async throws {
        let (db, tmp) = try makeDatabase()
        _ = tmp // keep the temp dir alive for the test's duration
        let store = LiveAnnotationStore(database: db)
        let scoreID = ScoreItemID()
        try await insertScore(db, id: scoreID)

        let neutralBytes = Data([0x46, 0x49, 0x4E, 0x4B, 0x01]) // "FINK" + version
        let legacyBytes = Data([0x62, 0x70, 0x6C, 0x69, 0x73, 0x74]) // "bplist"
        // Fake transcode: any non-neutral input becomes neutral; already-neutral -> nil (unchanged).
        let transcode: @Sendable (Data) -> Data? = { d in
            d.starts(with: Data([0x46, 0x49, 0x4E, 0x4B])) ? nil : Data([0x46, 0x49, 0x4E, 0x4B, 0x01])
        }

        let anchor = MusicalAnchor(measureIndex: 0, tickInMeasure: 0, partIndex: 0, staffIndexInPart: 0,
                                   dxSp: 0, verticalOffsetSp: 0)
        let layer = AnnotationLayer(
            scoreItemID: scoreID,
            drawings: [DrawingAnchor(kind: .musical(anchor), encodedDrawing: legacyBytes)],
            textBoxes: [], updatedAt: Date(timeIntervalSince1970: 0),
        )
        try await store.saveAnnotationLayer(layer)

        let migrator = AnnotationFormatMigrator(database: db)
        let firstPass = try await migrator.migrate(transcode: transcode)
        #expect(firstPass == 1)

        let migrated = try await store.annotationLayer(forScoreItem: scoreID)
        #expect(migrated?.drawings.first?.encodedDrawing == neutralBytes)

        // Second pass rewrites nothing (idempotent).
        let secondPass = try await migrator.migrate(transcode: transcode)
        #expect(secondPass == 0)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run (from `Packages/Infrastructure`):
```bash
xcodebuild test -scheme Infrastructure-Package \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' \
  -skipPackagePluginValidation \
  -only-testing:InfrastructureTests/AnnotationFormatMigratorTests
```
Expected: FAIL — `cannot find 'AnnotationFormatMigrator' in scope`.

- [ ] **Step 3: Write the migrator**

Create `Packages/Infrastructure/Sources/Persistence/AnnotationFormatMigrator.swift`:

```swift
import Domain
import Foundation
import GRDB

/// One-time pass that rewrites every `annotation_layers` row's per-drawing `encodedDrawing` through an injected
/// `transcode` closure (legacy PKDrawing bytes -> neutral InkStroke bytes; `nil` = leave unchanged). Persistence must
/// not import PencilKit, so the transcode is supplied by the composition root using the Reader bridge. Idempotent:
/// a drawing already in the neutral format transcodes to `nil` and is skipped, so re-running rewrites nothing.
public struct AnnotationFormatMigrator {
    private let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    /// Returns the number of layers actually rewritten.
    public func migrate(transcode: @Sendable (Data) -> Data?) async throws -> Int {
        do {
            let records: [AnnotationLayerRecord] = try await database.pool.read { db in
                try AnnotationLayerRecord.fetchAll(db)
            }
            var rewritten = 0
            for record in records {
                let layer = try record.toDomain()
                var changed = false
                var newDrawings = layer.drawings
                for i in newDrawings.indices {
                    if let neutral = transcode(newDrawings[i].encodedDrawing) {
                        newDrawings[i].encodedDrawing = neutral
                        changed = true
                    }
                }
                guard changed else { continue }
                let updated = AnnotationLayer(
                    id: layer.id, scoreItemID: layer.scoreItemID,
                    drawings: newDrawings, textBoxes: layer.textBoxes, updatedAt: layer.updatedAt,
                )
                let newRecord = try AnnotationLayerRecord(domain: updated)
                try await database.pool.write { db in try newRecord.save(db) }
                rewritten += 1
            }
            return rewritten
        } catch {
            throw DomainError.persistenceFailed(reason: "annotation format migration failed: \(error)")
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run (from `Packages/Infrastructure`):
```bash
xcodebuild test -scheme Infrastructure-Package \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' \
  -skipPackagePluginValidation \
  -only-testing:InfrastructureTests/AnnotationFormatMigratorTests
```
Expected: PASS. (The `updatedAt` is intentionally preserved so a format-only rewrite does not bump the layer's mtime and trigger spurious CloudKit churn.)

- [ ] **Step 5: Wire the migrator at app startup**

In `App/AppBootstrap.swift`, right after `let annotationStore = LiveAnnotationStore(database: database)` (line 70), add a one-time guarded run. First add the flag key near the other keys (top of the file or alongside `PrivacySettingsKey`):

```swift
private enum AnnotationMigrationKey {
    static let neutralFormatMigrated = "annotation.neutralFormatMigrated.v1"
}
```

Then, after `self.annotationStore = annotationStore` is set (line 95 area), kick off the migration off the main thread, once:

```swift
        if !UserDefaults.standard.bool(forKey: AnnotationMigrationKey.neutralFormatMigrated) {
            let migrator = AnnotationFormatMigrator(database: database)
            Task.detached(priority: .utility) {
                do {
                    _ = try await migrator.migrate(transcode: { data in
                        InkStrokePencilKitBridge.inkStrokeDataFromLegacyPKDrawing(data)
                    })
                    UserDefaults.standard.set(true, forKey: AnnotationMigrationKey.neutralFormatMigrated)
                } catch {
                    // Non-fatal: read-both keeps the app correct; retry on next launch (flag stays unset).
                }
            }
        }
```

Add `import Reader` and `import Persistence` at the top of `AppBootstrap.swift` if not already imported (check the existing import list first).

- [ ] **Step 6: Build the app to verify wiring compiles**

Run (from repo root):
```bash
xcodebuild -project Folino.xcodeproj -scheme Folino \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' \
  -skipPackagePluginValidation build
```
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 7: Commit**

```bash
git add Packages/Infrastructure/Sources/Persistence/AnnotationFormatMigrator.swift \
        Packages/Infrastructure/Tests/InfrastructureTests/Persistence/AnnotationFormatMigratorTests.swift \
        App/AppBootstrap.swift
git commit -m "feat: one-time migration of stored annotations to neutral format"
```

---

### Task 5: Preservation guarantee (unknown-format ink is never dropped)

**Files:**
- Test: `Packages/Infrastructure/Tests/InfrastructureTests/Persistence/AnnotationOpaquePreservationTests.swift`
- Test: `Packages/Features/Reader/Tests/ReaderTests/AnnotationUnknownFormatTests.swift`

**Interfaces:**
- Consumes: `LiveAnnotationStore` (Persistence), `AnnotationAnchoring.display` + `InkStrokePencilKitBridge.decodeStoredDrawing` (Reader).

This task adds no product code — it locks in, as tests, the two properties the spec's "preserve don't clobber" insurance relies on: (1) an `encodedDrawing` in an **unknown** format survives a save→load round-trip byte-for-byte (opaque through Persistence/CloudSync); (2) `display` skips an undecodable stroke for rendering but does **not** mutate/drop it from the model. If either test cannot pass with current code, that reveals a real clobber path to fix.

- [ ] **Step 1: Write the persistence preservation test**

Create `Packages/Infrastructure/Tests/InfrastructureTests/Persistence/AnnotationOpaquePreservationTests.swift` (same `makeDatabase` / `insertScore` helpers as the migrator test):

```swift
@testable import Domain
import Foundation
import GRDB
@testable import Persistence
import Testing

@MainActor
struct AnnotationOpaquePreservationTests {
    private func makeDatabase() throws -> (AppDatabase, TempDirectory) {
        let tmp = try TempDirectory()
        let db = try AppDatabase(databaseURL: tmp.url.appending(path: "f.sqlite"))
        return (db, tmp)
    }

    private func insertScore(_ db: AppDatabase, id: ScoreItemID) async throws {
        try await db.pool.write { db in
            try db.execute(
                sql: """
                INSERT INTO score_items (id, title, local_file_name, content_hash,
                    size_bytes, length_beats, default_tempo_bpm, added_at)
                VALUES (?, 'T', 'f.mscx', 'h', 0, 0, 120, 0)
                """,
                arguments: [id.rawValue.uuidString],
            )
        }
    }

    @Test func unknownFormatDrawingSurvivesRoundTrip() async throws {
        let (db, tmp) = try makeDatabase()
        _ = tmp
        let store = LiveAnnotationStore(database: db)
        let scoreID = ScoreItemID()
        try await insertScore(db, id: scoreID)

        let futureBytes = Data([0x00, 0x99, 0x99, 0x99, 0x42, 0x43]) // neither PKDrawing nor InkStroke
        let anchor = MusicalAnchor(measureIndex: 0, tickInMeasure: 0, partIndex: 0, staffIndexInPart: 0,
                                   dxSp: 0, verticalOffsetSp: 0)
        let layer = AnnotationLayer(
            scoreItemID: scoreID,
            drawings: [DrawingAnchor(kind: .musical(anchor), encodedDrawing: futureBytes)],
            textBoxes: [], updatedAt: Date(timeIntervalSince1970: 0),
        )
        try await store.saveAnnotationLayer(layer)
        let loaded = try await store.annotationLayer(forScoreItem: scoreID)
        #expect(loaded?.drawings.first?.encodedDrawing == futureBytes)
    }
}
```

- [ ] **Step 2: Write the Reader display-preservation test**

Create `Packages/Features/Reader/Tests/ReaderTests/AnnotationUnknownFormatTests.swift`:

```swift
import CoreGraphics
import Domain
import PencilKit
@testable import Reader
import SheetMusicCore
import SheetMusicLayout
import Testing

@Suite("Annotation unknown format")
struct AnnotationUnknownFormatTests {
    private let _install: Void = LayoutTestSupport.installed

    private func doc(staffSize: CGFloat = 28) -> LayoutDocument {
        let note = Note(pitch: 60, tpc: 14)
        let chord = Chord(duration: .whole, notes: [note])
        let measure = Measure(voices: [Voice(elements: [.chord(chord)])])
        let staff = Staff(measures: [measure, measure])
        let score = Score(division: 480, parts: [Part(id: "1", instrument: Instrument(id: "x"), staves: [staff])])
        var options = ScoreViewOptions()
        options.staffSize = staffSize
        return LayoutEngine.layout(score: score, options: options, availableWidth: 800)
    }

    @Test func undecodableDrawingIsSkippedNotCrashing() {
        let d = doc()
        let bogus = DrawingAnchor(
            kind: .musical(MusicalAnchor(measureIndex: 0, tickInMeasure: 0, partIndex: 0, staffIndexInPart: 0,
                                         dxSp: 0, verticalOffsetSp: 0)),
            encodedDrawing: Data([0x00, 0x99, 0x99, 0x99]),
        )
        // Rendering an undecodable drawing yields an empty PKDrawing (skipped), never a crash.
        let rendered = AnnotationAnchoring.display([bogus], in: d)
        #expect(rendered.strokes.isEmpty)
    }

    @Test func decodeReturnsNilForUnknownFormat() {
        #expect(InkStrokePencilKitBridge.decodeStoredDrawing(Data([0x00, 0x99, 0x99, 0x99])) == nil)
    }
}
```

- [ ] **Step 3: Run both tests**

Run (from `Packages/Infrastructure`):
```bash
xcodebuild test -scheme Infrastructure-Package \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' \
  -skipPackagePluginValidation \
  -only-testing:InfrastructureTests/AnnotationOpaquePreservationTests
```
Run (from `Packages/Features/Reader`):
```bash
xcodebuild test -scheme Reader \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' \
  -skipPackagePluginValidation \
  -only-testing:ReaderTests/AnnotationUnknownFormatTests
```
Expected: both PASS. If `unknownFormatDrawingSurvivesRoundTrip` fails, the persistence layer is mutating opaque bytes — fix that before proceeding. If `undecodableDrawingIsSkippedNotCrashing` fails, `display` is crashing/mutating on decode failure — make it `continue` past undecodable drawings without removing them from the model.

- [ ] **Step 4: Commit**

```bash
git add Packages/Infrastructure/Tests/InfrastructureTests/Persistence/AnnotationOpaquePreservationTests.swift \
        Packages/Features/Reader/Tests/ReaderTests/AnnotationUnknownFormatTests.swift
git commit -m "test: lock in opaque preservation of unknown-format annotation ink"
```

---

## Final verification (whole feature)

- [ ] **Run each affected package's full test suite** (Domain, Reader, Infrastructure-Package) with the commands above (drop the `-only-testing` filter). All green.
- [ ] **Build the app** (`xcodebuild ... -scheme Folino ... build`) → `BUILD SUCCEEDED`.
- [ ] **Manual smoke (hand to user / real device):** on a device with existing annotation data — launch (migration runs once), open an annotated score, confirm existing ink renders unchanged; draw a new stroke, background/foreground, confirm it persists and re-renders after reflow (rotate / change staff visibility). This is the "no user-visible change" acceptance check. Per project convention, do not launch the simulator for this — the user performs the clean-build device check.

## Notes for the executor

- **Read-both is what makes this safe.** After Task 3, the app is already fully correct with old data (it reads legacy PKDrawing). Task 4 (the one-time migration) is the "convert everything now" step the user chose — it is independently shippable and can even land in a follow-up commit if Task 3 needs to ship first.
- **Do not touch anchoring math.** Tasks 3's only changes are the encode/decode byte-boundary calls. The existing capture→display exact-round-trip invariant must stay green.
- **`updatedAt` preservation** in the migrator is deliberate — a format-only rewrite must not bump mtimes and cause CloudKit sync churn across the user's devices.
- **In-place vs backup blob.** The spec (§9) mentioned keeping the original PKDrawing as a transitional backup. This plan rewrites **in place** instead — justified by three guards: the codec is validated (Task 2) before it ever writes, `read-both` keeps the app correct regardless, and the migration is idempotent and re-runs on failure (the flag stays unset). If you want reversibility, the safe cheaper alternative is to **not eagerly migrate at all** and rely on read-both (lazy conversion on next edit) — but the user explicitly chose one-time conversion. Do not add a backup column without asking.
- **Migrator loads all layers into memory.** Fine at current scale (≈dozens of layers). If the base grows before this ships, page the fetch.
- **Phase 2 (Android) is out of scope here** — see `docs/superpowers/specs/2026-07-13-android-annotation-design.md` §2.1.
