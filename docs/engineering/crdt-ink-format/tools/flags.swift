import CoreGraphics
import Foundation

/// PDF annotation flag bits (PDF 32000-1, table 165), 1-based:
///   1 Invisible  2 Hidden  3 Print  4 NoZoom  5 NoRotate  6 NoView
///   7 ReadOnly   8 Locked  9 ToggleNoView  10 LockedContents
func describe(_ f: Int) -> String {
    let names = [
        (1, "Invisible"), (2, "Hidden"), (3, "Print"), (4, "NoZoom"), (5, "NoRotate"),
        (6, "NoView"), (7, "ReadOnly"), (8, "Locked"), (9, "ToggleNoView"), (10, "LockedContents"),
    ]
    let on = names.filter { f & (1 << ($0.0 - 1)) != 0 }.map(\.1)
    return on.isEmpty ? "none" : on.joined(separator: "+")
}

for path in CommandLine.arguments.dropFirst() {
    print("\n=== \(URL(fileURLWithPath: path).lastPathComponent)")
    guard let provider = CGDataProvider(url: URL(fileURLWithPath: path) as CFURL),
          let doc = CGPDFDocument(provider) else { print("open failed"); continue }
    for n in 1 ... doc.numberOfPages {
        guard let page = doc.page(at: n), let pd = page.dictionary else { continue }
        var annots: CGPDFArrayRef?
        guard CGPDFDictionaryGetArray(pd, "Annots", &annots), let annots else { continue }
        for i in 0 ..< CGPDFArrayGetCount(annots) {
            var ad: CGPDFDictionaryRef?
            guard CGPDFArrayGetDictionary(annots, i, &ad), let ad else { continue }
            var sub: UnsafePointer<Int8>?
            CGPDFDictionaryGetName(ad, "Subtype", &sub)
            var f: CGPDFInteger = 0
            let hasF = CGPDFDictionaryGetInteger(ad, "F", &f)
            var title: CGPDFStringRef?
            let hasT = CGPDFDictionaryGetString(ad, "T", &title)
            let titleText = hasT ? (title.flatMap { CGPDFStringCopyTextString($0) as String? } ?? "?") : "(none)"
            var name: UnsafePointer<Int8>?
            let hasName = CGPDFDictionaryGetName(ad, "Name", &name)
            print("  page \(n) \(sub.map { String(cString: $0) } ?? "?"): "
                + "F=\(hasF ? String(f) : "absent") [\(describe(Int(f)))] "
                + "T=\(titleText) Name=\(hasName ? (name.map { String(cString: $0) } ?? "?") : "absent")")
        }
    }
}
