import AppKit
import Foundation
import PencilKit

// Build a one-stroke PKDrawing from a CSV of canvas-space points and write PKDrawing.dataRepresentation().
//   mkwrd <points.csv> <out.wrd> [azimuth] [altitude] [heightRatio]
// CSV: first line 'tool,r,g,b,a' (tool = com.apple.ink.pen | com.apple.ink.marker), then x,y,t,w,force.
// Prints the drawing's bounds (canvas units) — the archive rectangle and /Rect derive from it.

let args = CommandLine.arguments
let csv = try! String(contentsOfFile: args[1], encoding: .utf8)
let azimuth = args.count > 3 ? Double(args[3])! : Double.pi / 3
let altitude = args.count > 4 ? Double(args[4])! : Double.pi / 3
let heightRatio = args.count > 5 ? Double(args[5])! : 1.0

var lines = csv.split(separator: "\n").map(String.init)
let head = lines.removeFirst().split(separator: ",").map(String.init)
let inkType: PKInkingTool.InkType = head[0] == "com.apple.ink.marker" ? .marker : .pen
let color = NSColor(
    srgbRed: CGFloat(Double(head[1])!),
    green: CGFloat(Double(head[2])!),
    blue: CGFloat(Double(head[3])!),
    alpha: CGFloat(Double(head[4])!),
)

FileHandle.standardError.write("parsed header \(head)\n".data(using: .utf8)!)
var points: [PKStrokePoint] = []
for line in lines {
    let v = line.split(separator: ",").map { Double($0)! }
    points.append(PKStrokePoint(
        location: CGPoint(x: v[0], y: v[1]), timeOffset: v[2],
        size: CGSize(width: v[3], height: v[3] * heightRatio), opacity: 1,
        force: CGFloat(v[4]), azimuth: CGFloat(azimuth), altitude: CGFloat(altitude),
    ))
}

FileHandle.standardError.write("built \(points.count) points\n".data(using: .utf8)!)
let path = PKStrokePath(controlPoints: points, creationDate: Date())
FileHandle.standardError.write("path ok\n".data(using: .utf8)!)
let stroke = PKStroke(ink: PKInk(inkType, color: color), path: path)
FileHandle.standardError.write("stroke ok\n".data(using: .utf8)!)
_ = NSApplication.shared
var drawing = PKDrawing()
drawing.strokes.append(stroke)
FileHandle.standardError.write("drawing ok\n".data(using: .utf8)!)
let data = drawing.dataRepresentation()
try! data.write(to: URL(fileURLWithPath: args[2]))
let b = drawing.bounds
print("wrote \(args[2]) \(data.count) bytes  magic \(data.prefix(8).map { String(format: "%02x", $0) }.joined(separator: " "))")
print("bounds \(b.minX) \(b.minY) \(b.width) \(b.height)")
print("renderBounds \(stroke.renderBounds)  points \(points.count)  ink \(inkType.rawValue)")
