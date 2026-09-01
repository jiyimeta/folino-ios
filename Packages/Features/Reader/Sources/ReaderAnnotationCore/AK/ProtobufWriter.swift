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
