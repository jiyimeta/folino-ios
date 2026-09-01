import Foundation

/// Raw DEFLATE, with no zlib or gzip framing around it.
///
/// Every platform has a deflate and none of them agree on how to reach it: iOS has `Compression`, Android's Swift
/// does not. The framing is identical everywhere, so it lives here and only this one call crosses the seam.
public protocol Deflating {
    func deflate(_ data: Data) throws -> Data
}

/// Wraps raw DEFLATE in a gzip container, which is what Apple's ink payload is stored as.
public enum GzipWriter {
    public enum GzipError: Error { case deflateFailed }

    public static func gzip(_ data: Data, using deflater: Deflating) throws -> Data {
        // Magic, CM = 8 (deflate), no flags, mtime 0, XFL 0, OS 255 (unknown). A fixed mtime keeps the output
        // reproducible, which is what lets a golden test compare bytes at all.
        var out = Data([0x1F, 0x8B, 0x08, 0x00, 0, 0, 0, 0, 0x00, 0xFF])
        try out.append(deflater.deflate(data))
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
