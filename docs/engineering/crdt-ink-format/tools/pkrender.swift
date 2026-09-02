import AppKit
import Foundation
import PencilKit

// Render a PKDrawing archive to PNG with PencilKit's own renderer, at a fixed scale (pixels per drawing unit).
//   pkrender <drawing.wrd> <out.png> <scale> [forceOverride]
// Must run from inside an .app bundle (PencilKit needs a bundle identifier).

let args = CommandLine.arguments
let data = try! Data(contentsOf: URL(fileURLWithPath: args[1]))
var drawing = try! PKDrawing(data: data)
let scale = CGFloat(Double(args[3])!)
if args.count > 4, let f = Double(args[4]) {
    drawing = PKDrawing(strokes: drawing.strokes.map { s in
        let pts = s.path.map { p in
            PKStrokePoint(
                location: p.location,
                timeOffset: p.timeOffset,
                size: p.size,
                opacity: p.opacity,
                force: CGFloat(f),
                azimuth: p.azimuth,
                altitude: p.altitude,
            )
        }
        return PKStroke(ink: s.ink, path: PKStrokePath(controlPoints: pts, creationDate: s.path.creationDate))
    })
}

let bounds = drawing.bounds.insetBy(dx: -10, dy: -10)
let image = drawing.image(from: bounds, scale: scale)
guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
// Composite over white so the measurement tools see opaque ink.
let w = Int(bounds.width * scale), h = Int(bounds.height * scale)
let cs = CGColorSpaceCreateDeviceRGB()
let ctx = CGContext(
    data: nil,
    width: w,
    height: h,
    bitsPerComponent: 8,
    bytesPerRow: w * 4,
    space: cs,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue,
)!
ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
if let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
}

let out = ctx.makeImage()!
let outRep = NSBitmapImageRep(cgImage: out)
try! outRep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[2]))
_ = png
print("wrote \(args[2]) \(w)x\(h) at \(scale) px/unit, bounds \(bounds)")
