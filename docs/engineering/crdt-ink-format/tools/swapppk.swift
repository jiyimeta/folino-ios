import Foundation
import PDFKit

// Controlled experiment: take Apple Books' own annotated PDF and change EXACTLY ONE thing — the PencilKit
// container inside /AAPL:AKExtras → /PPK — swapping Books' `crdt` blob for a `wrd` blob produced by folino.
// Everything else (subtype, flags, /PPKType, the raster /AP, the page content) stays Apple's.
//
// If the eraser stops working on the result, the container is the gate.
// If it keeps working, the container is not the gate and something else explains the refusal.
//
// usage: swapppk <books.pdf> <folino.pdf> <out.pdf>

let booksPath = CommandLine.arguments[1]
let folinoPath = CommandLine.arguments[2]
let outPath = CommandLine.arguments[3]

func firstPPK(_ path: String) -> String? {
    guard let doc = PDFDocument(data: try! Data(contentsOf: URL(fileURLWithPath: path))) else { return nil }
    for i in 0 ..< doc.pageCount {
        guard let page = doc.page(at: i) else { continue }
        for a in page.annotations {
            for (k, v) in a.annotationKeyValues where "\(k)".contains("AKExtras") {
                if let dict = v as? [AnyHashable: Any] {
                    for (dk, dv) in dict where "\(dk)".contains("PPK") && !"\(dk)".contains("Type") {
                        if let s = dv as? String {
                            return s
                        }
                    }
                }
            }
        }
    }
    return nil
}

func magic(_ b64: String) -> String {
    guard let d = Data(base64Encoded: b64, options: .ignoreUnknownCharacters) else { return "not base64" }
    let head = [UInt8](d.prefix(4))
    let ascii = String(bytes: head.map { $0 >= 32 && $0 < 127 ? $0 : 0x2E }, encoding: .ascii) ?? "?"
    return "\"\(ascii)\" \(d.count) bytes"
}

guard let folinoPPK = firstPPK(folinoPath) else { print("no /PPK in folino file"); exit(1) }
print("folino /PPK:", magic(folinoPPK))

let booksData = try Data(contentsOf: URL(fileURLWithPath: booksPath))
guard let doc = PDFDocument(data: booksData) else { print("books open failed"); exit(1) }

var swapped = 0
for i in 0 ..< doc.pageCount {
    guard let page = doc.page(at: i) else { continue }
    for a in page.annotations {
        for (k, v) in a.annotationKeyValues where "\(k)".contains("AKExtras") {
            guard var dict = v as? [AnyHashable: Any] else { continue }
            guard let existing = dict.first(where: { "\($0.key)".contains("PPK") && !"\($0.key)".contains("Type") })
            else { continue }
            print("page \(i + 1): Books /PPK was", magic(existing.value as? String ?? ""), "-> replacing")
            dict[existing.key] = folinoPPK
            a.setValue(dict, forAnnotationKey: PDFAnnotationKey(rawValue: "\(k)"))
            swapped += 1
        }
    }
}

print("annotations swapped:", swapped)

guard let out = doc.dataRepresentation() else { print("save failed"); exit(1) }
try out.write(to: URL(fileURLWithPath: outPath))
print("wrote", outPath, out.count, "bytes")

// Read it back and confirm the swap survived the save.
if let check = PDFDocument(data: out) {
    for i in 0 ..< check.pageCount {
        guard let page = check.page(at: i) else { continue }
        for a in page.annotations {
            for (k, v) in a.annotationKeyValues where "\(k)".contains("AKExtras") {
                if let dict = v as? [AnyHashable: Any] {
                    for (dk, dv) in dict where "\(dk)".contains("PPK") && !"\(dk)".contains("Type") {
                        print("  verify page \(i + 1):", magic(dv as? String ?? ""))
                    }
                }
            }
        }
    }
}
