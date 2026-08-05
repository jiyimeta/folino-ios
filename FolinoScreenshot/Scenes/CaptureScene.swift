import Domain
import PencilKit
import Reader
import ScreenshotKit
import SwiftUI
import UIKit

/// On-device tool (NOT part of the store deck) for capturing REAL Apple Pencil / finger ink to feed the annotation
/// marketing scene. Shows the same fixture score as `AnnotationScene` with a live `PKCanvasView` on top; you draw the
/// practice circle + fingerings naturally, then Copy (base64) or Share (a `.drawing` file) the `PKDrawing` out. The
/// captured strokes are later re-rendered by `AnnotationInkOverlay` as SwiftUI paths (PencilKit itself doesn't
/// composite into the Simulator framebuffer), so the marketing shot carries your actual hand strokes.
///
/// Reached when the app launches with NO `-ScreenshotScene` argument (i.e. tapping the icon or a plain Xcode Run on a
/// device), so it never appears in the automated capture run.
struct CaptureScene: View {
    @Environment(\.screenshotIdiom) private var idiom
    @State private var drawing = PKDrawing()
    @State private var status = "Draw the circle + fingerings, then Copy or Share"
    @State private var fileURL: URL?

    init() {
        ScreenshotSetup.ensure()
        UserDefaults.standard.set(ReaderLayoutMode.vertical.rawValue, forKey: ReaderGlobalSettingsKey.layoutMode)
        UserDefaults.standard.set(false, forKey: ReaderGlobalSettingsKey.showSeekBarEnabled)
    }

    private var idiomTag: String {
        idiom == .iPad ? "ipad" : "iphone"
    }

    var body: some View {
        ZStack {
            // The reference score (same as the annotation scene). Non-interactive so all touches reach the canvas.
            NavigationStack {
                ReaderRootScreen(
                    scoreItem: Fixture.items[0],
                    repository: FixtureScoreRepository(),
                    gateway: FixtureGateway(),
                    shareService: FixtureShareService(),
                    vocalTunerHandoff: NoopVocalTunerHandoff(),
                    metadataReader: FixtureMetadataReader(),
                    annotationCoordinator: .fixture,
                    scoresDirectory: URL(filePath: NSTemporaryDirectory()),
                    hidesBackButton: true,
                )
            }
            .allowsHitTesting(false)

            InkCaptureCanvas(drawing: $drawing)
                .ignoresSafeArea()

            // Controls pinned to the TOP so the bottom tool picker (PKToolPicker) never covers them.
            VStack(spacing: 8) {
                HStack(spacing: 12) {
                    Button("Copy base64", action: copyBase64)
                        .buttonStyle(.borderedProminent)
                    if let fileURL {
                        ShareLink(item: fileURL) {
                            Label("Share .drawing", systemImage: "square.and.arrow.up")
                        }
                        .buttonStyle(.bordered)
                    }
                    Button("Clear") { drawing = PKDrawing() }
                        .buttonStyle(.bordered)
                }
                Text(status)
                    .font(.caption2)
                    .padding(6)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
                Spacer()
            }
            .padding(.top, 16)
        }
        .onAppear { writeFile(drawing) } // set fileURL up front so Share shows before the first stroke
        .onChange(of: drawing) { _, new in
            writeFile(new)
            let data = new.dataRepresentation()
            status = "\(new.strokes.count) strokes · \(data.count) bytes · bounds \(shortRect(new.bounds))"
        }
    }

    /// Write the current drawing to a temp `.drawing` file (named by idiom) so the Share button can AirDrop it.
    private func writeFile(_ drawing: PKDrawing) {
        let url = URL(filePath: NSTemporaryDirectory()).appending(path: "ink-\(idiomTag).drawing")
        try? drawing.dataRepresentation().write(to: url)
        fileURL = url
    }

    private func copyBase64() {
        let data = drawing.dataRepresentation()
        UIPasteboard.general.string = data.base64EncodedString()
        status = "Copied base64 (\(data.count) bytes) for \(idiomTag) — paste it back to Claude"
    }

    private func shortRect(_ r: CGRect) -> String {
        "(\(Int(r.minX)),\(Int(r.minY)) \(Int(r.width))×\(Int(r.height)))"
    }
}

/// Wraps a live `PKCanvasView` with the system tool picker so you can pick red/blue pens and draw with Pencil/finger.
struct InkCaptureCanvas: UIViewRepresentable {
    @Binding var drawing: PKDrawing

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> PKCanvasView {
        let canvas = PKCanvasView()
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.drawingPolicy = .anyInput // finger too, so iPhone works without a Pencil
        canvas.delegate = context.coordinator
        canvas.drawing = drawing
        let picker = PKToolPicker()
        picker.addObserver(canvas)
        context.coordinator.toolPicker = picker
        DispatchQueue.main.async {
            canvas.becomeFirstResponder()
            picker.setVisible(true, forFirstResponder: canvas)
        }
        return canvas
    }

    func updateUIView(_ canvas: PKCanvasView, context: Context) {}

    final class Coordinator: NSObject, PKCanvasViewDelegate {
        let parent: InkCaptureCanvas
        var toolPicker: PKToolPicker?
        init(_ parent: InkCaptureCanvas) {
            self.parent = parent
        }

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            parent.drawing = canvasView.drawing
        }
    }
}
