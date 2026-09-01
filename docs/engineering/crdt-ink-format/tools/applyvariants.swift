import Foundation
import PDFKit

// Writes prepared AKAnnotationV2 archives back into a PDF, one per page, leaving every other page untouched
// so the untouched pages act as a control in the same document and the same viewing session.
//
//   applyvariants <source.pdf> <out.pdf> <page>:<archive>[:x,y,w,h] [...]
//
// `page` is 1-based. The archive replaces the value of /AAPL:AKExtras → /AAPL:AKAnnotationV2 on that page's
// first annotation; every other key on the annotation, and the page content, is left exactly as it was.
//
// The optional `x,y,w,h` also sets the annotation's own /Rect. That matters: a payload whose rectangle
// disagrees with the annotation's /Rect is rejected wholesale by Apple's markup — it neither erases nor
// selects — so any variant that moves the ink has to move both.

let args = Array(CommandLine.arguments.dropFirst())
guard args.count >= 3 else {
    print("usage: applyvariants <source.pdf> <out.pdf> <page>:<archive> ...")
    exit(2)
}

let sourcePath = args[0]
let outPath = args[1]

var replacements: [Int: Data] = [:]
var rects: [Int: CGRect] = [:]
var selfRect: Set<Int> = []
for spec in args.dropFirst(2) {
    let parts = spec.split(separator: ":")
    guard parts.count >= 2, let page = Int(parts[0]),
          let data = FileManager.default.contents(atPath: String(parts[1]))
    else {
        print("bad spec: \(spec)")
        exit(2)
    }
    replacements[page] = data
    if parts.count >= 3 {
        if parts[2] == "self" {
            // Exercise the setter with the annotation's own current value, so the only variable is the act of
            // writing /Rect rather than the value written.
            selfRect.insert(page)
        } else {
            let n = parts[2].split(separator: ",").compactMap { Double($0) }
            guard n.count == 4 else {
                print("bad rect in spec: \(spec)")
                exit(2)
            }
            rects[page] = CGRect(x: n[0], y: n[1], width: n[2], height: n[3])
        }
    }
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
        if selfRect.contains(page) {
            let current = annotation.bounds
            annotation.bounds = current
            print("page \(page): /Rect re-set to its own value \(current)")
        } else if let rect = rects[page] {
            annotation.bounds = rect
            print("page \(page): /Rect set to \(rect)")
        }
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
