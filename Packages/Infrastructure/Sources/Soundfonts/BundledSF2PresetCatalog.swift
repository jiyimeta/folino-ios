import Domain
import Foundation

/// In-memory `(bank, program) -> name` lookup built from the SoundFont 2
/// preset-header (`phdr`) chunk of a bundled `.sf2` file. Loading is lazy
/// and only reads the small `pdta` LIST chunk — sample data (the bulk of
/// the file) is never touched, so init costs are dominated by I/O setup
/// rather than 200 MB of throughput.
public struct BundledSF2PresetCatalog: SoundfontPresetCatalog {
    private let names: [BankProgram: String]

    public init(sf2URL: URL) throws {
        let handle = try FileHandle(forReadingFrom: sf2URL)
        defer { try? handle.close() }
        names = try Self.parsePresetNames(handle: handle)
    }

    public func presetName(bank: Int, program: Int) -> String? {
        names[BankProgram(bank: bank, program: program)]
    }

    // MARK: - Parser

    private struct BankProgram: Hashable {
        let bank: Int
        let program: Int
    }

    private enum ParseError: Error {
        case notSF2
        case truncated
        case missingPDTA
        case missingPHDR
        case malformedPHDR
    }

    private static let phdrRecordSize = 38

    private static func parsePresetNames(handle: FileHandle) throws -> [BankProgram: String] {
        // RIFF header: "RIFF" + size(LE u32) + "sfbk"
        let riffHeader = try read(handle: handle, count: 12)
        guard riffHeader.prefix(4) == Data("RIFF".utf8),
              riffHeader.suffix(4) == Data("sfbk".utf8)
        else { throw ParseError.notSF2 }

        // Walk top-level chunks looking for LIST .. pdta.
        let pdtaPayload = try findPDTAPayload(handle: handle)
        let phdr = try findPHDR(in: pdtaPayload)
        return parsePHDR(phdr)
    }

    private static func findPDTAPayload(handle: FileHandle) throws -> Data {
        while true {
            let headerData = try? handle.read(upToCount: 8)
            guard let header = headerData, header.count == 8 else {
                throw ParseError.missingPDTA
            }
            let id = String(bytes: header.prefix(4), encoding: .utf8) ?? ""
            let size = Int(readLEUInt32(header, offset: 4))
            // Chunks are padded to an even number of bytes.
            let paddedSize = size + (size & 1)
            guard id == "LIST" else {
                _ = try handle.seek(toOffset: handle.offsetInFile + UInt64(paddedSize))
                continue
            }
            guard let typeData = try handle.read(upToCount: 4), typeData.count == 4 else {
                throw ParseError.truncated
            }
            let listType = String(bytes: typeData, encoding: .utf8) ?? ""
            let bodySize = paddedSize - 4
            if listType == "pdta" {
                guard let body = try handle.read(upToCount: bodySize), body.count == bodySize else {
                    throw ParseError.truncated
                }
                return body
            }
            _ = try handle.seek(toOffset: handle.offsetInFile + UInt64(bodySize))
        }
    }

    private static func findPHDR(in pdta: Data) throws -> Data {
        var cursor = 0
        while cursor + 8 <= pdta.count {
            let id = String(
                bytes: pdta[cursor ..< cursor + 4], encoding: .utf8,
            ) ?? ""
            let size = Int(readLEUInt32(pdta, offset: cursor + 4))
            let paddedSize = size + (size & 1)
            let payloadStart = cursor + 8
            let payloadEnd = payloadStart + size
            guard payloadEnd <= pdta.count else { throw ParseError.malformedPHDR }
            if id == "phdr" {
                return pdta.subdata(in: payloadStart ..< payloadEnd)
            }
            cursor = payloadStart + paddedSize
        }
        throw ParseError.missingPHDR
    }

    private static func parsePHDR(_ data: Data) -> [BankProgram: String] {
        let recordCount = data.count / phdrRecordSize
        var result: [BankProgram: String] = [:]
        // The final record is the "EOP" terminator and is not a real preset.
        for index in 0 ..< max(recordCount - 1, 0) {
            let start = index * phdrRecordSize
            let record = data.subdata(in: start ..< start + phdrRecordSize)
            let nameBytes = record.prefix(20)
            let name = nullTerminatedString(nameBytes)
            let preset = Int(readLEUInt16(record, offset: 20))
            let bank = Int(readLEUInt16(record, offset: 22))
            // Skip the "EOP" sentinel even if it appears earlier in the table.
            guard name != "EOP" else { continue }
            result[BankProgram(bank: bank, program: preset)] = name
        }
        return result
    }

    // MARK: - Byte helpers

    private static func read(handle: FileHandle, count: Int) throws -> Data {
        guard let data = try handle.read(upToCount: count), data.count == count else {
            throw ParseError.truncated
        }
        return data
    }

    private static func readLEUInt16(_ data: Data, offset: Int) -> UInt16 {
        let lo = UInt16(data[data.startIndex + offset])
        let hi = UInt16(data[data.startIndex + offset + 1])
        return lo | (hi << 8)
    }

    private static func readLEUInt32(_ data: Data, offset: Int) -> UInt32 {
        let b0 = UInt32(data[data.startIndex + offset])
        let b1 = UInt32(data[data.startIndex + offset + 1])
        let b2 = UInt32(data[data.startIndex + offset + 2])
        let b3 = UInt32(data[data.startIndex + offset + 3])
        return b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)
    }

    private static func nullTerminatedString(_ data: Data) -> String {
        let end = data.firstIndex(of: 0) ?? data.endIndex
        let slice = data[data.startIndex ..< end]
        return (String(bytes: slice, encoding: .utf8) ?? "")
            .trimmingCharacters(in: .whitespaces)
    }
}
