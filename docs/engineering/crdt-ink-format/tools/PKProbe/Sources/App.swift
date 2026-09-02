import PencilKit
import UIKit

// A full-screen PKCanvasView showing calibration strokes, so the live PencilKit renderer can be measured from a
// simulator screenshot. Launch argument `zoom=<n>` sets the canvas zoomScale (default 1).

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?,
    ) -> Bool {
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = ProbeViewController()
        window.makeKeyAndVisible()
        self.window = window
        return true
    }
}

final class ProbeViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .white
        let zoom = CGFloat(Double(UserDefaults.standard.string(forKey: "zoom") ?? "1") ?? 1)

        struct Row { let ink: PKInkingTool.InkType; let size: CGFloat; let force: CGFloat }
        var rows: [Row] = []
        let page = UserDefaults.standard.string(forKey: "page") ?? "A"
        let inks: [PKInkingTool.InkType] = page == "A" ? [.pen, .pencil, .monoline] : [.fountainPen, .watercolor, .crayon, .marker]
        for ink in inks {
            for size in [4.0, 8.0, 16.0] {
                rows.append(Row(ink: ink, size: size, force: 0))
            }
        }
        // Content units: rows 60 apart, lines from x=20 to x=120 (a zoomed canvas shows content * zoom).
        var strokes: [PKStroke] = []
        for (i, row) in rows.enumerated() {
            let y = 60 + CGFloat(i) * 70
            let pts = (0 ... 50).map { k in
                PKStrokePoint(
                    location: CGPoint(x: 20 + CGFloat(k) * 2, y: y),
                    timeOffset: Double(k) * 0.005,
                    size: CGSize(width: row.size, height: row.size * (row.ink == .marker ? 1.032 : 1)),
                    opacity: 1,
                    force: row.force,
                    azimuth: 0,
                    altitude: .pi / 3,
                )
            }
            let color = row.ink == .marker ? UIColor(red: 1, green: 0, blue: 0, alpha: 0.8) : UIColor.red
            strokes.append(PKStroke(ink: PKInk(row.ink, color: color), path: PKStrokePath(controlPoints: pts, creationDate: Date())))
        }

        let canvas = PKCanvasView(frame: view.bounds)
        canvas.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        canvas.backgroundColor = .white
        canvas.drawingPolicy = .anyInput
        canvas.minimumZoomScale = 0.1
        canvas.maximumZoomScale = 10
        canvas.contentSize = CGSize(width: 400, height: 60 + CGFloat(rows.count) * 70 + 40)
        canvas.drawing = PKDrawing(strokes: strokes)
        view.addSubview(canvas)
        canvas.zoomScale = zoom
        canvas.contentOffset = .zero
        // Rows are at y = 40 + 60 i (content units); thickness is measured off the screenshot by bands.py.
        print("PKProbe zoom \(zoom) rows \(rows.map { "\($0.ink.rawValue) size \($0.size) force \($0.force)" })")
    }
}
