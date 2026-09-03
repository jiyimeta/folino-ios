import AppKit
import CoreGraphics
import Foundation
import PDFKit

let path = CommandLine.arguments[1]
let data = try! Data(contentsOf: URL(fileURLWithPath: path))
print("file bytes:", data.count)

guard let doc = PDFDocument(data: data) else { print("PDFKit could not open it"); exit(1) }
print("pages:", doc.pageCount)

/// ---- PDFKit's view of the annotations -------------------------------------------------------------------
var total = 0
for i in 0 ..< doc.pageCount {
    guard let page = doc.page(at: i) else { continue }
    let annots = page.annotations
    guard !annots.isEmpty else { continue }
    print("\npage \(i + 1): \(annots.count) annotation(s)")
    total += annots.count
    for (n, a) in annots.enumerated() {
        print("  [\(n)] type=\(a.type ?? "nil") bounds=\(a.bounds)")
        print("       color=\(a.color) borderWidth=\(a.border?.lineWidth ?? -1) style=\(a.border?.style.rawValue ?? -1)")
        // paths(): the ink polylines PDFKit exposes for an ink annotation
        if let paths = a.paths {
            let counts = paths.map(\.elementCount)
            print("       paths=\(paths.count) elementCounts=\(counts.prefix(8))\(counts.count > 8 ? "..." : "")")
        } else {
            print("       paths=nil")
        }
        // Every raw key on the annotation dictionary, so Apple-private entries are visible.
        let keys = a.annotationKeyValues.keys.map { "\($0)" }.sorted()
        print("       keys=\(keys)")
    }
}

print("\ntotal annotations:", total)

// ---- Raw byte reconnaissance ----------------------------------------------------------------------------
// Uncompressed PDF markers are readable even when streams are Flate-compressed.
let text = String(decoding: data, as: UTF8.self)
let markers = [
    "/Annots", "/Ink", "/InkList", "/AP", "/Subtype", "/Square", "/Highlight", "/FreeText",
    "/StrikeOut", "/Underline", "/Widget", "/Popup", "/PieceInfo", "/AAPL", "/Apple", "PencilKit",
    "/Type1", "/TrueType", "/Image", "/DCTDecode", "/FlateDecode",
]
print("\nraw markers present:")
for m in markers where text.contains(m) {
    let count = text.components(separatedBy: m).count - 1
    print("  \(m) x\(count)")
}

/// ---- Is the ink in the page body, or in annotations? -----------------------------------------------------
/// drawPDFPage replays ONLY the content stream (no annotations); PDFPage.draw includes annotations.
/// If the two renders differ, the ink lives in annotations. If they match, it was flattened into the body.
func render(_ viaPDFKit: Bool, page index: Int) -> [UInt8] {
    guard let provider = CGDataProvider(data: data as CFData),
          let cgDoc = CGPDFDocument(provider), let cgPage = cgDoc.page(at: index + 1) else { return [] }
    let box = cgPage.getBoxRect(.mediaBox)
    let w = Int(box.width), h = Int(box.height)
    guard w > 0, h > 0 else { return [] }
    var buf = [UInt8](repeating: 0, count: w * h * 4)
    guard let ctx = CGContext(
        data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue,
    ) else { return [] }
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h)))
    ctx.translateBy(x: -box.origin.x, y: -box.origin.y)
    if viaPDFKit, let page = doc.page(at: index) {
        let gc = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = gc
        page.draw(with: .mediaBox, to: ctx)
        NSGraphicsContext.restoreGraphicsState()
    } else {
        ctx.drawPDFPage(cgPage)
    }
    return buf
}

print("\nbody-vs-annotation comparison (differing pixels means the ink is an annotation, not baked in):")
for i in 0 ..< min(doc.pageCount, 6) {
    let withAnnots = render(true, page: i)
    let bodyOnly = render(false, page: i)
    guard withAnnots.count == bodyOnly.count, !withAnnots.isEmpty else { continue }
    var diff = 0
    for j in stride(from: 0, to: withAnnots.count, by: 4) where
        withAnnots[j] != bodyOnly[j] || withAnnots[j + 1] != bodyOnly[j + 1] || withAnnots[j + 2] != bodyOnly[j + 2]
    {
        diff += 1
    }
    print("  page \(i + 1): differing pixels = \(diff)")
}
