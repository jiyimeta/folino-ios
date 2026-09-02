import AppKit
import Foundation
import PDFKit

// Replace the AKAnnotationV2 archive of ONE annotation (by index) on page 1, leaving everything else untouched.
//   applyone <source.pdf> <out.pdf> <annotIndex> <archive.bin> [x,y,w,h]
// The optional rect also sets the annotation's /Rect (page space, y up) — needed whenever the archive's
// rectangle moved, because a payload whose rectangle disagrees with /Rect is discarded wholesale.

let args = Array(CommandLine.arguments.dropFirst())
guard args.count >= 4, let index = Int(args[2]),
      let sourceData = FileManager.default.contents(atPath: args[0]),
      let archive = FileManager.default.contents(atPath: args[3]),
      let doc = PDFDocument(data: sourceData), let page = doc.page(at: 0)
else { print("usage: applyone <source.pdf> <out.pdf> <annotIndex> <archive.bin> [x,y,w,h]"); exit(2) }

let annotations = page.annotations
guard index < annotations.count else { print("only \(annotations.count) annotations"); exit(1) }
let annotation = annotations[index]
var replaced = false
for (key, value) in annotation.annotationKeyValues where "\(key)".contains("AKExtras") {
    guard var dict = value as? [AnyHashable: Any] else { continue }
    guard let target = dict.keys.first(where: { "\($0)".contains("AKAnnotationV2") }) else { continue }
    dict[target] = archive.base64EncodedString()
    annotation.setValue(dict, forAnnotationKey: PDFAnnotationKey(rawValue: "\(key)"))
    replaced = true
}

if args.count >= 5 {
    let n = args[4].split(separator: ",").compactMap { Double($0) }
    guard n.count == 4 else { print("bad rect \(args[4])"); exit(2) }
    // Paths are stored relative to bounds.origin, so moving the bounds would drag /InkList along. Re-add
    // every path shifted back so the ink's absolute page position is unchanged and only /Rect moves.
    let old = annotation.bounds
    let paths = annotation.paths ?? []
    for p in paths {
        annotation.remove(p)
    }
    annotation.bounds = CGRect(x: n[0], y: n[1], width: n[2], height: n[3])
    var shift = CGAffineTransform(translationX: old.minX - n[0], y: old.minY - n[1])
    for p in paths {
        guard let cg = p.cgPath.copy(using: &shift) else { continue }
        annotation.add(NSBezierPath(cgPath: cg))
    }
    print("/Rect set to \(annotation.bounds); \(paths.count) path(s) re-added with shift \(shift.tx),\(shift.ty)")
}

guard replaced, let out = doc.dataRepresentation() else { print("nothing replaced, or save failed"); exit(1) }
try out.write(to: URL(fileURLWithPath: args[1]))
print("wrote \(args[1]) — annotation \(index) archive replaced (\(archive.count) bytes)")

if let check = PDFDocument(data: out), let p = check.page(at: 0) {
    for (i, a) in p.annotations.enumerated() {
        for (key, value) in a.annotationKeyValues where "\(key)".contains("AKExtras") {
            guard let dict = value as? [AnyHashable: Any] else { continue }
            for (dk, dv) in dict where "\(dk)".contains("AKAnnotationV2") {
                let n = (dv as? String).flatMap { Data(base64Encoded: $0, options: .ignoreUnknownCharacters)?.count }
                print("  verify annot \(i): \(n.map(String.init) ?? "unreadable") bytes, rect \(a.bounds)")
            }
        }
    }
}
