import CoreGraphics
import Foundation
import PDFKit

// Render one page at high resolution and measure the vertical run of inked pixels inside a rect, column by
// column, to recover the rendered stroke thickness in points.
//
//   measurewidth <pdf> <page(1-based)> <x0> <y0> <x1> <y1> [scale]
// The rect is in PDF page space (y up). Prints min / median / max run length in points across the columns.

let args = CommandLine.arguments
let path = args[1]
let pageIndex = Int(args[2])! - 1
let x0 = Double(args[3])!, y0 = Double(args[4])!, x1 = Double(args[5])!, y1 = Double(args[6])!
let scale = args.count > 7 ? Double(args[7])! : 8

guard let doc = PDFDocument(url: URL(fileURLWithPath: path)), let page = doc.page(at: pageIndex) else {
    print("open failed"); exit(1)
}

let media = page.bounds(for: .mediaBox)
let w = Int(media.width * scale), h = Int(media.height * scale)
let cs = CGColorSpaceCreateDeviceRGB()
guard let ctx = CGContext(
    data: nil,
    width: w,
    height: h,
    bitsPerComponent: 8,
    bytesPerRow: w * 4,
    space: cs,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue,
) else { exit(1) }
ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
ctx.scaleBy(x: scale, y: scale)
ctx.translateBy(x: -media.minX, y: -media.minY)
page.draw(with: .mediaBox, to: ctx)

let data = ctx.data!.assumingMemoryBound(to: UInt8.self)
func inked(_ px: Int, _ py: Int) -> Bool {
    // bitmap row 0 is the TOP (CGContext with bottom-left origin stores rows bottom-up? No: CGBitmapContext rows
    // start at the top-left of the flipped space; we drew with y up so row index = h - 1 - y*scale).
    let row = h - 1 - py
    let i = (row * w + px) * 4
    let r = Int(data[i]), g = Int(data[i + 1]), b = Int(data[i + 2])
    return (r + g + b) < 3 * 245
}

var runs: [Double] = []
let px0 = Int(x0 * scale), px1 = Int(x1 * scale)
let py0 = Int(y0 * scale), py1 = Int(y1 * scale)
for px in px0 ..< px1 {
    var best = 0, cur = 0
    for py in py0 ..< py1 {
        if inked(px, py) {
            cur += 1; best = max(best, cur)
        } else {
            cur = 0
        }
    }
    if best > 0 {
        runs.append(Double(best) / scale)
    }
}

runs.sort()
if runs.isEmpty {
    print("no ink in rect"); exit(0)
}

print("columns with ink: \(runs.count)/\(px1 - px0)")
print(String(
    format: "run length pt: min %.3f  p10 %.3f  median %.3f  p90 %.3f  max %.3f",
    runs[0],
    runs[runs.count / 10],
    runs[runs.count / 2],
    runs[runs.count * 9 / 10],
    runs[runs.count - 1],
))
