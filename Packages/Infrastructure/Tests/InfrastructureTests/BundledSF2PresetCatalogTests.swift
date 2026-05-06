import Foundation
import Soundfonts
import Testing

@Suite struct BundledSF2PresetCatalogTests {
    @Test func parsesMinimalSyntheticSF2() throws {
        let url = try writeSyntheticSF2(presets: [
            (bank: 0, program: 0, name: "Acoustic Grand Piano"),
            (bank: 17, program: 43, name: "Contrabass Expr."),
            (bank: 128, program: 0, name: "Standard"),
        ])
        defer { try? FileManager.default.removeItem(at: url) }

        let catalog = try BundledSF2PresetCatalog(sf2URL: url)
        #expect(catalog.presetName(bank: 0, program: 0) == "Acoustic Grand Piano")
        #expect(catalog.presetName(bank: 17, program: 43) == "Contrabass Expr.")
        #expect(catalog.presetName(bank: 128, program: 0) == "Standard")
        #expect(catalog.presetName(bank: 99, program: 99) == nil)
    }

    @Test func skipsOverInfoAndSdtaListsBeforePDTA() throws {
        // Realistic SF2 layout: INFO and sdta come before pdta — the parser
        // needs to step past them to find the preset table.
        let url = try writeSyntheticSF2(
            presets: [(bank: 8, program: 0, name: "Bright Piano")],
            includeLeadingInfoAndSdta: true
        )
        defer { try? FileManager.default.removeItem(at: url) }

        let catalog = try BundledSF2PresetCatalog(sf2URL: url)
        #expect(catalog.presetName(bank: 8, program: 0) == "Bright Piano")
    }

    // MARK: - SF2 builder

    private func writeSyntheticSF2(
        presets: [(bank: Int, program: Int, name: String)],
        includeLeadingInfoAndSdta: Bool = false
    ) throws -> URL {
        var phdr = Data()
        for preset in presets {
            phdr.append(presetHeader(name: preset.name, bank: preset.bank, program: preset.program))
        }
        // EOP terminator record.
        phdr.append(presetHeader(name: "EOP", bank: 0, program: 0))

        let phdrChunk = chunk(id: "phdr", payload: phdr)
        var pdtaPayload = Data("pdta".utf8)
        pdtaPayload.append(phdrChunk)
        let pdtaList = chunk(id: "LIST", payload: pdtaPayload)

        var sfbkBody = Data("sfbk".utf8)
        if includeLeadingInfoAndSdta {
            let infoBody = Data("INFO".utf8)
                + chunk(id: "ifil", payload: Data([2, 0, 1, 0]))
            sfbkBody.append(chunk(id: "LIST", payload: infoBody))
            let sdtaBody = Data("sdta".utf8)
                + chunk(id: "smpl", payload: Data(repeating: 0, count: 32))
            sfbkBody.append(chunk(id: "LIST", payload: sdtaBody))
        }
        sfbkBody.append(pdtaList)

        var file = Data("RIFF".utf8)
        file.append(le32(UInt32(sfbkBody.count)))
        file.append(sfbkBody)

        let url = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString)
            .appendingPathExtension("sf2")
        try file.write(to: url)
        return url
    }

    private func chunk(id: String, payload: Data) -> Data {
        var data = Data(id.utf8)
        data.append(le32(UInt32(payload.count)))
        data.append(payload)
        if payload.count.isMultiple(of: 2) == false {
            data.append(0)
        }
        return data
    }

    private func presetHeader(name: String, bank: Int, program: Int) -> Data {
        var rec = Data(count: 38)
        let nameBytes = Array(name.utf8.prefix(20))
        for (i, b) in nameBytes.enumerated() {
            rec[i] = b
        }
        rec[20] = UInt8(program & 0xFF)
        rec[21] = UInt8((program >> 8) & 0xFF)
        rec[22] = UInt8(bank & 0xFF)
        rec[23] = UInt8((bank >> 8) & 0xFF)
        return rec
    }

    private func le32(_ value: UInt32) -> Data {
        Data([
            UInt8(value & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 24) & 0xFF),
        ])
    }
}
