import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

// Render one page (with annotations) to PNG at a fixed pixels-per-point scale.
//   renderpage <pdf> <page(1-based)> <scale> <out.png>

let args = CommandLine.arguments
guard args.count == 5, let doc = PDFDocument(url: URL(fileURLWithPath: args[1])),
      let page = doc.page(at: Int(args[2])! - 1), let scale = Double(args[3])
else { print("usage: renderpage <pdf> <page> <scale> <out.png>"); exit(2) }

let media = page.bounds(for: .mediaBox)
let w = Int((media.width * scale).rounded()), h = Int((media.height * scale).rounded())
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
guard let image = ctx.makeImage(),
      let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: args[4]) as CFURL, UTType.png.identifier as CFString, 1, nil)
else { exit(1) }
CGImageDestinationAddImage(dest, image, nil)
CGImageDestinationFinalize(dest)
print("wrote \(args[4]) \(w)x\(h)")
