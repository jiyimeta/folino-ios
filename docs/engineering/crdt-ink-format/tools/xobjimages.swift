import CoreGraphics
import Foundation

// Print pixel dimensions of every image XObject inside each annotation's /AP /N stream.
//   xobjimages <pdf>

let path = CommandLine.arguments[1]
guard let provider = CGDataProvider(url: URL(fileURLWithPath: path) as CFURL),
      let doc = CGPDFDocument(provider) else { print("open failed"); exit(1) }

for n in 1 ... doc.numberOfPages {
    guard let page = doc.page(at: n), let pd = page.dictionary else { continue }
    var annots: CGPDFArrayRef?
    guard CGPDFDictionaryGetArray(pd, "Annots", &annots), let annots else { continue }
    for i in 0 ..< CGPDFArrayGetCount(annots) {
        var ad: CGPDFDictionaryRef?
        guard CGPDFArrayGetDictionary(annots, i, &ad), let ad else { continue }
        var ap: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(ad, "AP", &ap), let ap else { continue }
        var normal: CGPDFStreamRef?
        guard CGPDFDictionaryGetStream(ap, "N", &normal), let normal, let nd = CGPDFStreamGetDictionary(normal) else { continue }
        var res: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(nd, "Resources", &res), let res else { continue }
        var xo: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(res, "XObject", &xo), let xo else { continue }
        final class Box { var names: [String] = [] }
        let box = Box()
        CGPDFDictionaryApplyBlock(xo, { k, _, info in
            Unmanaged<Box>.fromOpaque(info!).takeUnretainedValue().names.append(String(cString: k))
            return true
        }, Unmanaged.passUnretained(box).toOpaque())
        for name in box.names {
            var s: CGPDFStreamRef?
            guard CGPDFDictionaryGetStream(xo, name, &s), let s, let sd = CGPDFStreamGetDictionary(s) else { continue }
            var w: CGPDFInteger = 0, h: CGPDFInteger = 0, bpc: CGPDFInteger = 0
            CGPDFDictionaryGetInteger(sd, "Width", &w)
            CGPDFDictionaryGetInteger(sd, "Height", &h)
            CGPDFDictionaryGetInteger(sd, "BitsPerComponent", &bpc)
            var cs: CGPDFObjectRef?
            var csName = "?"
            if CGPDFDictionaryGetObject(sd, "ColorSpace", &cs), let cs {
                var nm: UnsafePointer<Int8>?
                if CGPDFObjectGetValue(cs, .name, &nm), let nm {
                    csName = String(cString: nm)
                } else {
                    csName = "array"
                }
            }
            var smask: CGPDFStreamRef?
            let hasMask = CGPDFDictionaryGetStream(sd, "SMask", &smask)
            print("page \(n) annot \(i) \(name): \(w)x\(h) px, \(bpc) bpc, cs=\(csName), smask=\(hasMask)")
        }
    }
}
