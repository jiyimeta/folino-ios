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
///
/// `timeMillis` stores each sample's ABSOLUTE offset in milliseconds from the stroke's start (`p.timeOffset * 1000`,
/// clamped to `UInt16`), NOT deltas between consecutive samples. A `UInt16` ceiling means offsets beyond ~65s from
/// stroke start saturate at `UInt16.max` rather than wrapping — authoritative for any future decoder (e.g. the
/// Android/sharing side) that must match this byte layout exactly.
///
/// Extensibility discipline: a future channel may be added ONLY as a new flag bit plus a new, flag-gated array
/// appended at the END of the layout — never bump `version`, and never insert a channel in the middle of the
/// existing layout. Old decoders tolerate trailing bytes they don't know about (`remaining >= requiredBytes` only
/// checks what THAT decoder needs) and ignore unknown flag bits, so appending-only keeps v1 forward-compatible.
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
        for v in s.x {
            appendLE(&out, v.bitPattern)
        }
        for v in s.y {
            appendLE(&out, v.bitPattern)
        }
        for v in s.width {
            appendLE(&out, v.bitPattern)
        }
        if hasForce { for v in s.force {
            appendLE(&out, v.bitPattern)
        } }
        if hasTilt {
            for v in s.azimuth {
                appendLE(&out, v.bitPattern)
            }
            for v in s.altitude {
                appendLE(&out, v.bitPattern)
            }
        }
        if hasTime { for v in s.timeMillis {
            appendLE(&out, v)
        } }
        return out
    }

    public static func decode(_ data: Data) throws -> InkStroke {
        guard isInkStroke(data) else { throw InkStrokeCodecError.badMagic }
        var r = Reader(data)
        r.skip(4) // magic
        guard try r.u8() == version else { throw InkStrokeCodecError.unsupportedVersion }
        let tool = try InkStroke.Tool(rawValue: r.u8()) ?? .pen
        let flags = try r.u8()
        r.skip(1) // reserved
        let color = try r.u32()
        let baseWidth = try Float(bitPattern: r.u32())
        let opacity = try Float(bitPattern: r.u32())
        let count = try Int(r.u32())
        let hasForce = flags & 0b001 != 0
        let hasTilt = flags & 0b010 != 0
        let hasTime = flags & 0b100 != 0

        let floatChannels = 3 + (hasForce ? 1 : 0) + (hasTilt ? 2 : 0)
        let requiredBytes = count * 4 * floatChannels + count * 2 * (hasTime ? 1 : 0)
        guard r.remaining >= requiredBytes else { throw InkStrokeCodecError.truncated }

        func floats(_ n: Int) throws -> [Float] {
            var a = [Float](); a.reserveCapacity(n)
            for _ in 0 ..< n {
                try a.append(Float(bitPattern: r.u32()))
            }
            return a
        }
        let x = try floats(count)
        let y = try floats(count)
        let width = try floats(count)
        let force = hasForce ? try floats(count) : []
        let azimuth = hasTilt ? try floats(count) : []
        let altitude = hasTilt ? try floats(count) : []
        var time: [UInt16] = []
        if hasTime { time.reserveCapacity(count); for _ in 0 ..< count {
            try time.append(r.u16())
        } }

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
        init(_ data: Data) {
            self.data = data; offset = data.startIndex
        }

        mutating func skip(_ n: Int) {
            offset += n
        }

        var remaining: Int {
            data.endIndex - offset
        }

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
