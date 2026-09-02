import Domain
import Foundation

#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Encodes one `InkStroke` as the drawing payload inside Apple's `AKAnnotationV2` archive.
///
/// The measurements behind every constant are in `docs/engineering/crdt-ink-format/README.md`. The fields whose
/// meaning is still unknown are carried as one fixed set lifted from a real sample: they are not derivable, and
/// dropping them was tested on device and produced no ink, so they are not optional either. The structural golden
/// test in `AKInkGoldenTests` is what keeps them honest.
public enum AKInkPayloadEncoder {
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
    public static func payload(
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
        for i in stroke.x.indices where i < stroke.y.count {
            let t = i < stroke.timeMillis.count
                ? Float(stroke.timeMillis[i]) / 1000
                : Float(i) * 0.008 // a plausible cadence when the source device gave no timing
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
