import Foundation
import PDFKit

// Writes prepared AKAnnotationV2 archives back into a PDF, one per page, leaving every other page untouched
// so the untouched pages act as a control in the same document and the same viewing session.
//
//   applyvariants <source.pdf> <out.pdf> <page>:<archive> [<page>:<archive> ...]
//
// `page` is 1-based. The archive replaces the value of /AAPL:AKExtras → /AAPL:AKAnnotationV2 on that page's
// first annotation; every other key on the annotation, and the page content, is left exactly as it was.

let args = Array(CommandLine.arguments.dropFirst())
guard args.count >= 3 else {
    print("usage: applyvariants <source.pdf> <out.pdf> <page>:<archive> ...")
    exit(2)
}

let sourcePath = args[0]
let outPath = args[1]

var replacements: [Int: Data] = [:]
for spec in args.dropFirst(2) {
    let parts = spec.split(separator: ":", maxSplits: 1)
    guard parts.count == 2, let page = Int(parts[0]),
          let data = FileManager.default.contents(atPath: String(parts[1]))
    else {
        print("bad spec: \(spec)")
        exit(2)
    }
    replacements[page] = data
}

guard let sourceData = FileManager.default.contents(atPath: sourcePath),
      let doc = PDFDocument(data: sourceData)
else {
    print("cannot open \(sourcePath)")
    exit(1)
}

var applied = 0
for (page, archive) in replacements.sorted(by: { $0.key < $1.key }) {
    guard let pdfPage = doc.page(at: page - 1) else {
        print("page \(page) does not exist")
        continue
    }
    guard let annotation = pdfPage.annotations.first else {
        print("page \(page) has no annotation")
        continue
    }
    var replacedKey = false
    for (key, value) in annotation.annotationKeyValues where "\(key)".contains("AKExtras") {
        guard var dict = value as? [AnyHashable: Any] else { continue }
        let target = dict.keys.first { "\($0)".contains("AKAnnotationV2") }
        guard let target else { continue }
        dict[target] = archive.base64EncodedString()
        annotation.setValue(dict, forAnnotationKey: PDFAnnotationKey(rawValue: "\(key)"))
        replacedKey = true
    }
    if replacedKey {
        applied += 1
        print("page \(page): replaced AKAnnotationV2 (\(archive.count) bytes)")
    } else {
        print("page \(page): no AKExtras/AKAnnotationV2 to replace")
    }
}

guard applied > 0, let out = doc.dataRepresentation() else {
    print("nothing applied, or save failed")
    exit(1)
}

try out.write(to: URL(fileURLWithPath: outPath))
print("wrote \(outPath) — \(out.count) bytes, \(applied) page(s) modified")

// Read back and confirm each replacement survived serialization.
if let check = PDFDocument(data: out) {
    for page in replacements.keys.sorted() {
        guard let p = check.page(at: page - 1), let a = p.annotations.first else { continue }
        for (key, value) in a.annotationKeyValues where "\(key)".contains("AKExtras") {
            guard let dict = value as? [AnyHashable: Any] else { continue }
            for (dk, dv) in dict where "\(dk)".contains("AKAnnotationV2") {
                let n = (dv as? String).flatMap { Data(base64Encoded: $0, options: .ignoreUnknownCharacters)?.count }
                print("  verify page \(page): \(n.map(String.init) ?? "unreadable") bytes")
            }
        }
    }
}
