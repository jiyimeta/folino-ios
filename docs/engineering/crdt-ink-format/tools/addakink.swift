import Foundation
import PDFKit

// Adds an AKAnnotationV2 ink annotation to a document that never had one — the shape folino itself will use.
//
// Every test so far edited an annotation Apple had already written into a document Apple had already touched.
// That leaves two things unproven at once: whether the annotation works when WE create it, and whether it works
// in a document with no Apple provenance. This creates the annotation from nothing, on any PDF.
//
//   addakink <in.pdf>                                       print each page's MediaBox and annotations
//   addakink <in.pdf> <out.pdf> <page>:<archive>:x,y,w,h    add one annotation per spec (1-based page)
//
// The annotation is /Square with no border and no interior colour, carrying the archive under
// /AAPL:AKExtras -> /AAPL:AKAnnotationV2, exactly as Apple's own V2 annotations do. No /AP is written: the ink
// is invisible until something renders it, which makes "the eraser found it" an unambiguous signal on its own.

let args = Array(CommandLine.arguments.dropFirst())
guard let inPath = args.first, let doc = PDFDocument(url: URL(fileURLWithPath: inPath)) else {
    print("usage: addakink <in.pdf> [<out.pdf> <page>:<archive>:x,y,w,h ...]")
    exit(2)
}

guard args.count >= 3 else {
    for i in 0 ..< doc.pageCount {
        guard let page = doc.page(at: i) else { continue }
        let box = page.bounds(for: .mediaBox)
        let kinds = page.annotations.map { $0.type ?? "?" }.joined(separator: ",")
        print("page \(i + 1): mediaBox \(box.width) x \(box.height)"
            + "  annotations: \(page.annotations.isEmpty ? "none" : kinds)")
    }
    exit(0)
}

let outPath = args[1]
var added = 0
for spec in args.dropFirst(2) {
    let parts = spec.split(separator: ":")
    guard parts.count == 3, let pageNumber = Int(parts[0]),
          let archive = FileManager.default.contents(atPath: String(parts[1]))
    else {
        print("bad spec: \(spec)")
        exit(2)
    }
    let n = parts[2].split(separator: ",").compactMap { Double($0) }
    guard n.count == 4, let page = doc.page(at: pageNumber - 1) else {
        print("bad rect or page in spec: \(spec)")
        exit(2)
    }
    let rect = CGRect(x: n[0], y: n[1], width: n[2], height: n[3])

    let annotation = PDFAnnotation(bounds: rect, forType: .square, withProperties: nil)
    annotation.color = .clear
    annotation.interiorColor = nil
    annotation.border = PDFBorder()
    annotation.border?.lineWidth = 0
    annotation.setValue(
        ["AAPL:AKAnnotationV2": archive.base64EncodedString()],
        forAnnotationKey: PDFAnnotationKey(rawValue: "AAPL:AKExtras"),
    )
    page.addAnnotation(annotation)
    added += 1
    print("page \(pageNumber): added /Square + AKAnnotationV2 (\(archive.count) bytes) at \(rect)")
}

guard added > 0, let out = doc.dataRepresentation() else {
    print("nothing added, or save failed")
    exit(1)
}

try out.write(to: URL(fileURLWithPath: outPath))
print("wrote \(outPath) — \(out.count) bytes")

// Read back: an annotation whose key did not survive serialization would fail the test for the wrong reason.
if let check = PDFDocument(data: out) {
    for spec in args.dropFirst(2) {
        guard let pageNumber = Int(spec.split(separator: ":")[0]),
              let page = check.page(at: pageNumber - 1) else { continue }
        let carried = page.annotations.filter { a in
            a.annotationKeyValues.keys.contains { "\($0)".contains("AKExtras") }
        }
        print("  verify page \(pageNumber): \(carried.count) annotation(s) carrying AKExtras")
    }
}
