import Foundation
@testable import ReaderAnnotationCore
import Testing

@Suite("Protobuf writer")
struct AKProtobufWriterTests {
    @Test
    func `a varint field encodes as tag then value`() {
        var w = ProtobufWriter()
        w.varint(1, 10)
        // field 1, wire type 0 -> tag 0x08; value 10 -> 0x0A
        #expect(w.data == Data([0x08, 0x0A]))
    }

    @Test
    func `a float field uses wire type 5, little-endian`() {
        var w = ProtobufWriter()
        w.float(1, 1.0)
        // field 1, wire type 5 -> tag 0x0D; 1.0f -> 00 00 80 3F
        #expect(w.data == Data([0x0D, 0x00, 0x00, 0x80, 0x3F]))
    }

    @Test
    func `a nested message is length-prefixed`() {
        var w = ProtobufWriter()
        w.message(2) { inner in inner.varint(1, 1) }
        // field 2, wire type 2 -> tag 0x12; length 2; body 08 01
        #expect(w.data == Data([0x12, 0x02, 0x08, 0x01]))
    }

    @Test
    func `varints above 127 continue into a second byte`() {
        var w = ProtobufWriter()
        w.varint(1, 300)
        #expect(w.data == Data([0x08, 0xAC, 0x02]))
    }
}
