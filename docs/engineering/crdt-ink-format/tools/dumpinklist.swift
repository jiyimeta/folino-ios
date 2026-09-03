import Foundation
import PDFKit

// Print, for every /Ink annotation: /Rect, border width, color, and the first/last points of each /InkList path.

let path = CommandLine.arguments[1]
guard let doc = PDFDocument(data: try! Data(contentsOf: URL(fileURLWithPath: path))) else {
    print("open failed"); exit(1)
}

for i in 0 ..< doc.pageCount {
    guard let page = doc.page(at: i) else { continue }
    let media = page.bounds(for: .mediaBox)
    print("page \(i + 1) mediaBox \(media)")
    for (n, a) in page.annotations.enumerated() {
        print("  [\(n)] type=\(a.type ?? "?") rect=\(a.bounds) borderWidth=\(a.border?.lineWidth ?? -1) color=\(a.color)")
        if let bs = a.annotationKeyValues[PDFAnnotationKey.border] {
            print("      /BS=\(bs)")
        }
        for (k, v) in a.annotationKeyValues where "\(k)".contains("AAPL") {
            let key = "\(k)"
            if key.contains("AKExtras") {
                continue
            }
            print("      \(key)=\(String(describing: v).prefix(80))")
        }
        guard let paths = a.paths else { continue }
        for (p, bp) in paths.enumerated() {
            let count = bp.elementCount
            var pts: [CGPoint] = []
            for e in 0 ..< count {
                var buf = [CGPoint](repeating: .zero, count: 3)
                _ = bp.element(at: e, associatedPoints: &buf)
                pts.append(buf[0])
            }
            let bb = bp.bounds
            print("      path[\(p)] \(count) points, bounds=\(bb) (page space = rect.origin + pt)")
            for q in pts.prefix(3) {
                print("         first (\(q.x + a.bounds.minX), \(q.y + a.bounds.minY))  raw (\(q.x), \(q.y))")
            }
            for q in pts.suffix(2) {
                print("         last  (\(q.x + a.bounds.minX), \(q.y + a.bounds.minY))  raw (\(q.x), \(q.y))")
            }
        }
    }
}
