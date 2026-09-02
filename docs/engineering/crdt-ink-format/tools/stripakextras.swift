import Foundation
import PDFKit

// Removes /AAPL:AKExtras from every annotation, leaving everything else byte-for-byte alone.
//
// The export keeps subtype /Ink specifically so editors that know nothing about Apple's markup can still
// select and delete a mark. Adding AKExtras is supposed to be additive. This is the control that tests that
// claim: same document, same annotations, same geometry, one key removed. If the stripped file behaves
// differently in a viewer, the key is not additive after all and the spec's "Explicitly unchanged" is wrong.
//
//   stripakextras <in.pdf> <out.pdf>

let args = Array(CommandLine.arguments.dropFirst())
guard args.count == 2, let doc = PDFDocument(url: URL(fileURLWithPath: args[0])) else {
    print("usage: stripakextras <in.pdf> <out.pdf>")
    exit(2)
}

var removed = 0
var inspected = 0
for pageIndex in 0 ..< doc.pageCount {
    guard let page = doc.page(at: pageIndex) else { continue }
    for annotation in page.annotations {
        inspected += 1
        let key = PDFAnnotationKey(rawValue: "AAPL:AKExtras")
        guard annotation.value(forAnnotationKey: key) != nil else { continue }
        annotation.removeValue(forAnnotationKey: key)
        removed += 1
    }
}

guard let out = doc.dataRepresentation() else {
    print("serialization failed")
    exit(1)
}

try out.write(to: URL(fileURLWithPath: args[1]))
print("inspected \(inspected) annotation(s), removed AKExtras from \(removed)")
print("wrote \(args[1]) — \(out.count) bytes")

// Read back and confirm the key is gone and the ink survived, so a null result cannot be a silent write bug.
if let check = PDFDocument(data: out) {
    for pageIndex in 0 ..< check.pageCount {
        guard let page = check.page(at: pageIndex) else { continue }
        for annotation in page.annotations {
            let extras = annotation.value(forAnnotationKey: PDFAnnotationKey(rawValue: "AAPL:AKExtras"))
            let paths = annotation.paths?.count ?? -1
            print("  page \(pageIndex + 1) \(annotation.type ?? "?"): AKExtras=\(extras == nil ? "gone" : "STILL THERE")"
                + "  paths=\(paths)  bounds=\(annotation.bounds)")
        }
    }
}
