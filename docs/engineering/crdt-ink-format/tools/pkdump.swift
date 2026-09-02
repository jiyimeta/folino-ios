import Foundation
import PencilKit

// Decode a PKDrawing archive (`wrd` container) with PencilKit itself and print every stroke's parameters.
//   pkdump <drawing.bin>

let path = CommandLine.arguments[1]
let data = try! Data(contentsOf: URL(fileURLWithPath: path))
let drawing: PKDrawing
do {
    drawing = try PKDrawing(data: data)
} catch {
    print("PKDrawing(data:) failed: \(error)")
    exit(1)
}

print("bounds \(drawing.bounds)   strokes \(drawing.strokes.count)")
for (i, s) in drawing.strokes.enumerated() {
    let ink = s.ink
    var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
    ink.color.usingColorSpace(.sRGB)?.getRed(&r, green: &g, blue: &b, alpha: &a)
    print("stroke \(i): inkType=\(ink.inkType.rawValue) color=(\(r), \(g), \(b), \(a)) transform=\(s.transform) mask=\(s.mask != nil)")
    print("   renderBounds \(s.renderBounds)  path count \(s.path.count)  creationDate \(s.path.creationDate)")
    let pts = Array(s.path)
    for (k, p) in pts.enumerated() where k < 3 || k >= pts.count - 2 {
        print(String(
            format: "   [%3d] loc (%.3f, %.3f) t=%.4f size (%.3f, %.3f) opacity %.3f force %.3f azimuth %.4f altitude %.4f",
            k,
            p.location.x,
            p.location.y,
            p.timeOffset,
            p.size.width,
            p.size.height,
            p.opacity,
            p.force,
            p.azimuth,
            p.altitude,
        ))
    }
    let sizes = pts.map(\.size.width)
    let forces = pts.map(\.force)
    let az = pts.map(\.azimuth)
    let al = pts.map(\.altitude)
    print(String(
        format: "   size %.3f..%.3f  force %.3f..%.3f  azimuth %.4f..%.4f  altitude %.4f..%.4f",
        sizes.min() ?? 0,
        sizes.max() ?? 0,
        forces.min() ?? 0,
        forces.max() ?? 0,
        az.min() ?? 0,
        az.max() ?? 0,
        al.min() ?? 0,
        al.max() ?? 0,
    ))
}
