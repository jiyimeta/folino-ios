import CoreGraphics
import Foundation

// Is Apple's ink appearance stream vector drawing, or a stamped raster?
// Walk /Annots -> /AP -> /N and look at the content stream's operators and resources.

let path = CommandLine.arguments[1]
guard let provider = CGDataProvider(url: URL(fileURLWithPath: path) as CFURL),
      let doc = CGPDFDocument(provider) else { print("open failed"); exit(1) }

func names(_ d: CGPDFDictionaryRef, _ key: String) -> [String] {
    var bucket: CGPDFDictionaryRef?
    guard CGPDFDictionaryGetDictionary(d, key, &bucket), let bucket else { return [] }
    final class Box { var v: [String] = [] }
    let box = Box()
    CGPDFDictionaryApplyBlock(bucket, { k, _, info in
        Unmanaged<Box>.fromOpaque(info!).takeUnretainedValue().v.append(String(cString: k))
        return true
    }, Unmanaged.passUnretained(box).toOpaque())
    return box.v
}

for n in 1 ... doc.numberOfPages {
    guard let page = doc.page(at: n), let pd = page.dictionary else { continue }
    var annots: CGPDFArrayRef?
    guard CGPDFDictionaryGetArray(pd, "Annots", &annots), let annots else { continue }
    for i in 0 ..< CGPDFArrayGetCount(annots) {
        var ad: CGPDFDictionaryRef?
        guard CGPDFArrayGetDictionary(annots, i, &ad), let ad else { continue }
        var sub: UnsafePointer<Int8>?
        CGPDFDictionaryGetName(ad, "Subtype", &sub)
        let subtype = sub.map { String(cString: $0) } ?? "?"

        var ap: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(ad, "AP", &ap), let ap else {
            print("page \(n) \(subtype): no /AP")
            continue
        }
        var normal: CGPDFStreamRef?
        guard CGPDFDictionaryGetStream(ap, "N", &normal), let normal,
              let nd = CGPDFStreamGetDictionary(normal)
        else {
            print("page \(n) \(subtype): /AP has no /N stream")
            continue
        }

        var res: CGPDFDictionaryRef?
        var xobjects: [String] = []
        var hasImageXObject = false
        if CGPDFDictionaryGetDictionary(nd, "Resources", &res), let res {
            xobjects = names(res, "XObject")
            var bucket: CGPDFDictionaryRef?
            if CGPDFDictionaryGetDictionary(res, "XObject", &bucket), let bucket {
                for name in xobjects {
                    var s: CGPDFStreamRef?
                    guard CGPDFDictionaryGetStream(bucket, name, &s), let s,
                          let sd = CGPDFStreamGetDictionary(s) else { continue }
                    var st: UnsafePointer<Int8>?
                    CGPDFDictionaryGetName(sd, "Subtype", &st)
                    if st.map({ String(cString: $0) }) == "Image" {
                        hasImageXObject = true
                    }
                }
            }
        }

        var fmt = CGPDFDataFormat.raw
        let body = (CGPDFStreamCopyData(normal, &fmt) as Data?) ?? Data()
        let text = String(decoding: body, as: UTF8.self)
        // Vector path operators vs. an XObject draw.
        let curves = text.components(separatedBy: " c\n").count - 1 + (text.components(separatedBy: " c ").count - 1)
        let lines = text.components(separatedBy: " l\n").count - 1 + (text.components(separatedBy: " l ").count - 1)
        let moves = text.components(separatedBy: " m\n").count - 1 + (text.components(separatedBy: " m ").count - 1)
        let draws = text.components(separatedBy: "Do").count - 1
        print("page \(n) \(subtype): AP stream \(body.count) bytes, xobjects=\(xobjects.count) imageXObject=\(hasImageXObject)")
        print("   path ops: m=\(moves) l=\(lines) c=\(curves)   'Do' (draw xobject)=\(draws)")
    }
}
