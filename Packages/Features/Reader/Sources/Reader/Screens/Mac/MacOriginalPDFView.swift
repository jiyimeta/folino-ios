// PARITY(macos): original-PDF reader extras — the Mac shows the document, the playback cursor and committed ink, and
//   resolves a click to a seek. What is still iOS-only: the score ⇄ original switch itself (`toggleDisplaySource`,
//   which needs reader chrome the Mac has not grown yet), the vertical / paged PDF layout modes and their page-turn
//   buttons, the PDF source notice, and the re-read flow. See `PagedPDFContainer` / `VerticalPDFContainer`.

#if os(macOS)
import AppKit
import Domain
import PDFKit
import PencilKit
import SwiftUI

/// The ORIGINAL imported PDF, shown by PDFKit, with a playback-cursor overlay, committed ink, and click-to-seek.
///
/// Distinct from `MacPagedScoreContainer`, which draws folino's own RE-ENGRAVED layout as a deck of sheets. This is
/// the document the user imported, pixel for pixel — the thing an item folino could not read into notation has instead
/// of a score, and the thing a converted item can be switched back to.
///
/// **Everything is drawn as a `PDFAnnotation` in page coordinates**, which is the whole reason this is an AppKit host
/// rather than a SwiftUI overlay: PDFKit owns the scroll and the zoom, so anything expressed in page space follows
/// them for free. A SwiftUI layer on top would have to reimplement both to stay registered with the pages.
///
/// Adapted from swift-sheet-music's own macOS example (`Examples/Apple/SheetMusicExample/macOS/OriginalPDFView.swift`)
/// — the same author's reference implementation — with the example's direct `PDFScoreGeometry` dependency replaced by
/// folino's `PDFPlaybackGeometry` seam (Features must not import the ssm PDF module) and the ink layer added.
///
/// **One coordinate flip runs through the whole file.** `PDFPlaybackGeometry` and `PDFAnnotationAnchoring` both speak
/// the reader's TOP-LEFT-origin page space (y down); PDFKit's page space is bottom-left-origin (y up). Every rect and
/// point crossing that seam goes through `MacPDFPageSpace`.
struct MacOriginalPDFView: NSViewRepresentable {
    let document: PDFDocument
    /// Where the playback cursor is, in top-left page space. `nil` hides it.
    let cursorRect: PDFCursorRect?
    /// Bring the cursor into view when it lands off-screen.
    let followsCursor: Bool
    /// Committed annotation ink for this item, still in its stored (normalized) form; each page's share is projected
    /// and flattened by the coordinator.
    let annotations: [DrawingAnchor]
    /// A click, resolved to a page index and a top-left page point. The caller turns it into a seek.
    let onClick: (Int, CGPoint) -> Void

    func makeNSView(context: Context) -> PDFView {
        let view = ClickablePDFView()
        view.document = document
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        // The desk this document sits on, and the ONLY place it is painted: `PDFView` draws an opaque background, so
        // a SwiftUI `.background` behind it would never be seen. The same appearance-keyed colour the page deck
        // uses, not a matching constant — see `MacReaderGround` for why one value serves both paint sites, and why
        // the desk follows the system while the pages do not.
        view.backgroundColor = MacReaderGround.deskColor
        view.onClick = { [weak coordinator = context.coordinator] point in
            coordinator?.handleClick(at: point)
        }
        context.coordinator.pdfView = view
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        context.coordinator.parent = self
        if view.document !== document {
            view.document = document
            context.coordinator.forgetInk()
        }
        context.coordinator.applyInkIfNeeded(annotations)
        context.coordinator.applyCursor(cursorRect)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    @MainActor
    final class Coordinator {
        var parent: MacOriginalPDFView
        weak var pdfView: PDFView?
        /// Which ink revision is currently drawn on the pages, or `nil` for none. The one piece of state behind
        /// `applyInkIfNeeded`: `updateNSView` runs on every playback tick and must not rasterize a page-sized image
        /// sixty times a second.
        private var appliedInkRevision: Int?
        private var active: (page: PDFPage, annotation: PDFAnnotation)?
        private var inkAnnotations: [(page: PDFPage, annotation: PDFAnnotation)] = []

        init(_ parent: MacOriginalPDFView) {
            self.parent = parent
        }

        /// Resolve a click (PDFView coords) to a page + top-left page point and report it.
        func handleClick(at viewPoint: CGPoint) {
            guard let pdfView, let document = pdfView.document,
                  let page = pdfView.page(for: viewPoint, nearest: true)
            else { return }
            let pagePoint = pdfView.convert(viewPoint, to: page)
            parent.onClick(
                document.index(for: page),
                MacPDFPageSpace.topLeftPoint(pagePoint, on: page),
            )
        }

        /// Move / draw / clear the cursor annotation.
        func applyCursor(_ cursorRect: PDFCursorRect?) {
            guard let pdfView, let document = pdfView.document else { return }
            clearActive()
            guard let cursorRect, let page = document.page(at: cursorRect.pageIndex) else { return }
            let bounds = MacPDFPageSpace.bottomLeftRect(cursorRect.rect, on: page)
            let annotation = PDFAnnotation(bounds: bounds, forType: .square, withProperties: nil)
            annotation.color = NSColor.controlAccentColor.withAlphaComponent(0.35)
            annotation.interiorColor = NSColor.controlAccentColor.withAlphaComponent(0.15)
            page.addAnnotation(annotation)
            active = (page, annotation)
            if parent.followsCursor {
                scrollIntoView(rect: bounds, on: page, pdfView: pdfView)
            }
        }

        /// Drop the record of what is drawn, so the next `applyInkIfNeeded` rebuilds it. Called when the document is
        /// swapped, which takes the old pages (and their annotations) with it.
        func forgetInk() {
            appliedInkRevision = nil
            inkAnnotations = []
        }

        /// Flatten each page's committed ink into one image annotation covering that page. Read-only: the Mac has no
        /// annotation input, so this is rebuilt only when the stored layer itself changes.
        func applyInkIfNeeded(_ drawings: [DrawingAnchor]) {
            let revision = drawings.hashValue
            guard appliedInkRevision != revision else { return }
            appliedInkRevision = revision
            for entry in inkAnnotations {
                entry.page.removeAnnotation(entry.annotation)
            }
            inkAnnotations = []
            guard let document = pdfView?.document, !drawings.isEmpty else { return }
            for index in 0 ..< document.pageCount {
                guard let page = document.page(at: index),
                      let annotation = MacPDFInkAnnotation.make(drawings, pageIndex: index, page: page)
                else { continue }
                page.addAnnotation(annotation)
                inkAnnotations.append((page, annotation))
            }
        }

        private func clearActive() {
            if let active {
                active.page.removeAnnotation(active.annotation)
            }
            active = nil
        }

        /// Scroll only when the cursor rect isn't already fully visible.
        private func scrollIntoView(rect: CGRect, on page: PDFPage, pdfView: PDFView) {
            let inView = pdfView.convert(rect, from: page)
            guard let docView = pdfView.documentView else { return }
            let visible = docView.convert(docView.visibleRect, to: pdfView)
            if !visible.contains(inView) {
                pdfView.go(to: rect, on: page)
            }
        }
    }
}

/// The top-left ⇄ bottom-left conversion, in one place. The reader's PDF geometry and its page-anchored ink are both
/// expressed with y growing DOWN from the page's top-left corner; PDFKit's page space grows UP from the bottom-left of
/// the mediaBox, which may itself sit at a non-zero origin.
///
/// **Known limit: `page.rotation` is ignored**, so a scan whose pages carry a 90°/180°/270° rotation entry puts both
/// the cursor bar and the ink in the unrotated frame — visibly wrong, not subtly. Carried over from the reference
/// implementation rather than introduced here; `PDFPlaybackGeometry`'s own `pageSizes` are unrotated mediaBox sizes
/// too, so closing it means rotating on both sides of the seam, not just in here.
enum MacPDFPageSpace {
    static func mediaBox(of page: PDFPage) -> CGRect {
        page.bounds(for: .mediaBox)
    }

    /// A PDFKit page point → the reader's top-left page space.
    static func topLeftPoint(_ point: CGPoint, on page: PDFPage) -> CGPoint {
        let box = mediaBox(of: page)
        return CGPoint(x: point.x - box.minX, y: box.height - (point.y - box.minY))
    }

    /// A reader top-left-space rect → PDFKit page coordinates.
    static func bottomLeftRect(_ rect: CGRect, on page: PDFPage) -> CGRect {
        let box = mediaBox(of: page)
        return CGRect(
            x: rect.minX + box.minX,
            y: box.minY + box.height - rect.maxY,
            width: rect.width,
            height: rect.height,
        )
    }
}

/// A page-sized annotation that draws one flattened raster of that page's committed ink.
///
/// A `PDFAnnotation` rather than a view on top of the `PDFView`: an annotation lives in page coordinates, so PDFKit's
/// own scroll and zoom carry it. The raster is produced by the same `PKDrawing.image(from:scale:)` the iOS reader's
/// `StaticInkLayer` uses — verified to work on macOS, where PencilKit ships the model and the raster but no
/// `PKCanvasView`.
final class MacPDFInkAnnotation: PDFAnnotation {
    private let image: CGImage

    /// `nil` when this page carries no ink, or when the raster could not be produced — never an empty annotation.
    static func make(_ drawings: [DrawingAnchor], pageIndex: Int, page: PDFPage) -> MacPDFInkAnnotation? {
        let box = MacPDFPageSpace.mediaBox(of: page)
        guard box.width > 0, box.height > 0 else { return nil }
        let pageFrame = CGRect(origin: .zero, size: box.size)
        let drawing = PDFAnnotationAnchoring.displayPage(drawings, pageIndex: pageIndex, pageFrame: pageFrame)
        guard !drawing.strokes.isEmpty else { return nil }
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let raster = drawing.image(from: pageFrame, scale: scale)
        guard let cgImage = raster.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        return MacPDFInkAnnotation(bounds: box, image: cgImage)
    }

    private init(bounds: CGRect, image: CGImage) {
        self.image = image
        super.init(bounds: bounds, forType: .stamp, withProperties: nil)
        shouldDisplay = true
        shouldPrint = true
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("MacPDFInkAnnotation is never loaded from an archive")
    }

    /// The context is already in page space (y up), and `CGContext.draw(_:in:)` puts an image's first row at the top
    /// of the destination rect there — so the top-left-origin raster lands the right way up with no flip of its own.
    override func draw(with _: PDFDisplayBox, in context: CGContext) {
        context.saveGState()
        context.draw(image, in: bounds)
        context.restoreGState()
    }
}

/// `PDFView` that reports a left-click as a point in its own coordinate space, bypassing the default text /
/// annotation selection so a click is a clean seek gesture. Scroll and zoom are unaffected.
///
/// Not calling `super.mouseDown` is what suppresses selection — deliberate, a click here means "seek". It also skips
/// the focus AppKit would normally take on a click, which would leave the arrow and page keys dead after the first
/// click, so focus is taken explicitly instead.
final class ClickablePDFView: PDFView {
    var onClick: ((CGPoint) -> Void)?

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        onClick?(point)
    }
}
#endif
