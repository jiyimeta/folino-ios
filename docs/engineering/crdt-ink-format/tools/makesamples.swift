import AppKit
import CoreGraphics
import CoreText
import Foundation

// Generates a sample-collection PDF for reverse-engineering Apple's `crdt` ink container.
// One controlled mark per page, one variable changed at a time, so differences between the resulting
// /AAPL:AKExtras → /PPK blobs isolate individual fields.

let pageW: CGFloat = 595, pageH: CGFloat = 842
let out = NSMutableData()
let consumer = CGDataConsumer(data: out)!
var box = CGRect(x: 0, y: 0, width: pageW, height: pageH)
let ctx = CGContext(consumer: consumer, mediaBox: &box, nil)!

struct Page {
    let n: Int
    let title: String
    let detail: String
    /// Guide geometry: where to draw, in page points (bottom-left origin).
    let guides: [(CGPoint, CGPoint)]
    let dot: CGPoint?
}

let pages: [Page] = [
    Page(
        n: 1,
        title: "基準",
        detail: "細い黒ペンで、下の線を1本だけなぞる",
        guides: [(CGPoint(x: 150, y: 500), CGPoint(x: 350, y: 500))],
        dot: nil,
    ),
    Page(
        n: 2,
        title: "同じものをもう一度",
        detail: "1ページ目と全く同じに。細い黒ペンで1本",
        guides: [(CGPoint(x: 150, y: 500), CGPoint(x: 350, y: 500))],
        dot: nil,
    ),
    Page(
        n: 3,
        title: "色だけ変える",
        detail: "太さは1ページ目と同じ。色を赤にして1本",
        guides: [(CGPoint(x: 150, y: 500), CGPoint(x: 350, y: 500))],
        dot: nil,
    ),
    Page(
        n: 4,
        title: "太さだけ変える",
        detail: "色は黒のまま。いちばん太くして1本",
        guides: [(CGPoint(x: 150, y: 500), CGPoint(x: 350, y: 500))],
        dot: nil,
    ),
    Page(
        n: 5,
        title: "本数を増やす",
        detail: "細い黒ペンで、上下2本とも別々に引く",
        guides: [
            (CGPoint(x: 150, y: 520), CGPoint(x: 350, y: 520)),
            (CGPoint(x: 150, y: 470), CGPoint(x: 350, y: 470)),
        ],
        dot: nil,
    ),
    Page(
        n: 6,
        title: "向きを変える",
        detail: "細い黒ペンで、縦の線を1本",
        guides: [(CGPoint(x: 250, y: 420), CGPoint(x: 250, y: 580))],
        dot: nil,
    ),
    Page(
        n: 7,
        title: "点",
        detail: "細い黒ペンで、印の位置を1回だけ軽く叩く",
        guides: [],
        dot: CGPoint(x: 250, y: 500),
    ),
    Page(
        n: 8,
        title: "長い曲線",
        detail: "細い黒ペンで、下の波線をゆっくりなぞる",
        guides: [],
        dot: nil,
    ),
]

func draw(_ text: String, at point: CGPoint, size: CGFloat, bold: Bool = false, gray: CGFloat = 0) {
    let font = CTFontCreateUIFontForLanguage(bold ? .emphasizedSystem : .system, size, "ja" as CFString)!
    let attrs: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: CGColor(gray: gray, alpha: 1),
    ]
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))
    ctx.textPosition = point
    CTLineDraw(line, ctx)
}

for page in pages {
    ctx.beginPDFPage(nil)

    draw("サンプル \(page.n) / 8 — \(page.title)", at: CGPoint(x: 60, y: pageH - 80), size: 22, bold: true)
    draw(page.detail, at: CGPoint(x: 60, y: pageH - 115), size: 15, gray: 0.25)
    draw(
        "※ 指示以外は何も描かないでください。1ページに1つだけ。",
        at: CGPoint(x: 60, y: pageH - 145),
        size: 12,
        gray: 0.45,
    )

    // Guides: dashed light-gray so they are easy to trace but obviously not ink.
    ctx.saveGState()
    ctx.setStrokeColor(CGColor(gray: 0.75, alpha: 1))
    ctx.setLineWidth(0.7)
    ctx.setLineDash(phase: 0, lengths: [5, 4])
    for (a, b) in page.guides {
        ctx.move(to: a); ctx.addLine(to: b)
    }
    if page.n == 8 {
        ctx.move(to: CGPoint(x: 120, y: 500))
        for i in 0 ... 100 {
            let t = CGFloat(i) / 100
            ctx.addLine(to: CGPoint(x: 120 + t * 360, y: 500 + 45 * sin(t * .pi * 4)))
        }
    }
    ctx.strokePath()
    ctx.restoreGState()

    if let dot = page.dot {
        ctx.saveGState()
        ctx.setStrokeColor(CGColor(gray: 0.75, alpha: 1))
        ctx.setLineWidth(0.7)
        ctx.strokeEllipse(in: CGRect(x: dot.x - 7, y: dot.y - 7, width: 14, height: 14))
        ctx.restoreGState()
    }

    ctx.endPDFPage()
}

ctx.closePDF()

let dest = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/ink-samples.pdf"
try! (out as Data).write(to: URL(fileURLWithPath: dest))
print("wrote \(dest) — \(pages.count) pages, \((out as Data).count) bytes")
