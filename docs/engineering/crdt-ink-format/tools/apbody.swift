import CoreGraphics
import Foundation

// Print the /AP /N content stream body (and its /BBox and /Matrix) of every annotation on page 1.

let path = CommandLine.arguments[1]
let maxBytes = CommandLine.arguments.count > 2 ? Int(CommandLine.arguments[2])! : 600
guard let provider = CGDataProvider(url: URL(fileURLWithPath: path) as CFURL),
      let doc = CGPDFDocument(provider) else { print("open failed"); exit(1) }

func numbers(_ d: CGPDFDictionaryRef, _ key: String) -> [Double] {
    var arr: CGPDFArrayRef?
    guard CGPDFDictionaryGetArray(d, key, &arr), let arr else { return [] }
    var out: [Double] = []
    for i in 0 ..< CGPDFArrayGetCount(arr) {
        var v: CGPDFReal = 0
        if CGPDFArrayGetNumber(arr, i, &v) {
            out.append(Double(v))
        }
    }
    return out
}

guard let page = doc.page(at: 1), let pd = page.dictionary else { exit(1) }
var annots: CGPDFArrayRef?
guard CGPDFDictionaryGetArray(pd, "Annots", &annots), let annots else { exit(1) }
for i in 0 ..< CGPDFArrayGetCount(annots) {
    var ad: CGPDFDictionaryRef?
    guard CGPDFArrayGetDictionary(annots, i, &ad), let ad else { continue }
    print("=== annot \(i) Rect=\(numbers(ad, "Rect"))")
    var ap: CGPDFDictionaryRef?
    guard CGPDFDictionaryGetDictionary(ad, "AP", &ap), let ap else { print("no /AP"); continue }
    var normal: CGPDFStreamRef?
    guard CGPDFDictionaryGetStream(ap, "N", &normal), let normal, let nd = CGPDFStreamGetDictionary(normal) else { continue }
    print("BBox=\(numbers(nd, "BBox")) Matrix=\(numbers(nd, "Matrix"))")
    var fmt = CGPDFDataFormat.raw
    let body = (CGPDFStreamCopyData(normal, &fmt) as Data?) ?? Data()
    let text = String(decoding: body, as: UTF8.self)
    print("stream \(body.count) bytes:")
    print(String(text.prefix(maxBytes)))
    if text.count > maxBytes {
        print("... [tail]"); print(String(text.suffix(200)))
    }
}
