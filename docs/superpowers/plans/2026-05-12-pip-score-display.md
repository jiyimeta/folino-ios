# PiP Score Display Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the user mirror the score view — horizontal layout with a live playback cursor — into a system Picture-in-Picture window so they can keep eyes on the music while another app is in the foreground (typical use case: a separate tuner app).

**Architecture:** Custom-content PiP via `AVPictureInPictureController` driven by an `AVSampleBufferDisplayLayer`. A frame pump renders the existing `HorizontalScoreContainer` SwiftUI view off-screen through a `UIHostingController` into `CVPixelBuffer`s pulled from a pool, wraps them in `CMSampleBuffer`s, and enqueues them on the display layer at ~20 fps while PiP is active. Cursor motion is discrete (chord boundary to chord boundary), so a low frame rate is enough. All new code lives inside the `Reader` feature package — AVKit/AVFoundation are system frameworks, not Folino Infrastructure modules, so the layered-module rule is preserved.

**Tech Stack:**
- AVKit — `AVPictureInPictureController`, `AVPictureInPictureControllerContentSource`, `AVPictureInPictureSampleBufferPlaybackDelegate`
- AVFoundation — `AVSampleBufferDisplayLayer`
- CoreVideo — `CVPixelBufferPool`, `CVPixelBuffer`
- CoreMedia — `CMSampleBuffer`, `CMVideoFormatDescription`
- UIKit — `UIHostingController`, `CADisplayLink`
- SwiftUI — existing `HorizontalScoreContainer`
- Swift Testing for the renderer

---

## File Structure

```
Packages/Features/Reader/Sources/Reader/PiP/
  ScorePiPFrameRenderer.swift          # SwiftUI view → CVPixelBuffer via offscreen UIHostingController
  ScorePiPPlaybackDelegate.swift       # AVPictureInPictureSampleBufferPlaybackDelegate impl
  ScorePiPCoordinator.swift            # Owns display layer + AVPictureInPictureController + frame pump
  ScorePiPHostView.swift               # UIViewRepresentable bridging coordinator into SwiftUI

Packages/Features/Reader/Sources/Reader/
  ReaderViewModel.swift                # Modify: expose isPiPActive, isPiPSupported, togglePiP()

Packages/Features/Reader/Sources/Reader/Screens/
  ReaderToolbar.swift                  # Modify: add PiP toggle button in top overlay
  ReaderRootScreen.swift               # Modify: install ScorePiPHostView as a zero-size overlay

Packages/Features/Reader/Tests/ReaderTests/PiP/
  ScorePiPFrameRendererTests.swift     # Snapshot of renderer output for a fixed Score

App/AppBootstrap.swift                 # Modify: set AVAudioSession category .playback active
                                       # (needed for audio + PiP to both keep working in background)
```

Each file has one responsibility. `PiP/` directory keeps the new code self-contained — easy to delete if we decide it's not worth shipping.

### Why this split

- **Renderer is unit-testable** — it takes a Score + size → CVPixelBuffer. We can snapshot-test it deterministically.
- **PlaybackDelegate is the AVKit-facing protocol object** — kept separate so it doesn't pull the AVKit imports into the coordinator's public surface.
- **Coordinator is the lifecycle owner** — frame pump (`CADisplayLink`), display layer, AVPictureInPictureController. Not unit-testable; verified manually.
- **HostView bridges into SwiftUI** — must live in the view tree so `AVPictureInPictureController` finds its host window.

### Why no Infrastructure module / no new Domain protocol

The architecture rule is **Feature → Folino's Infrastructure packages only via a Domain protocol**. AVKit/AVFoundation are *system* frameworks, not Folino Infrastructure modules — Reader already imports SwiftUI/UIKit directly under the same reasoning. Wrapping PiP in a Domain protocol would force the protocol surface to expose `CVPixelBuffer` / `CALayer` types, which violates the "Domain is Foundation-only" rule worse than just importing AVKit in Reader does. Keeping it in Reader is the lesser violation and the simpler design.

---

## Open assumptions (verify in Task 0)

- `AVAudioSession` is configured for `.playback` somewhere (likely inside `swift-sheet-music`'s `SheetMusicAudio`). If not, we add a small bootstrap call in `AppBootstrap`.
- `UIBackgroundModes` includes `audio` (confirmed: `App/Info.plist` has it).
- iOS 26 simulator supports custom PiP (it does, but the floating window behaves slightly differently than on device — verify in Task 8).

---

## Tasks

### Task 0: Confirm audio session + background mode prerequisites

**Files to read:**
- `App/Info.plist` — confirm `UIBackgroundModes` ⊇ `["audio"]` (we saw this in the survey)
- `Packages/Infrastructure/Sources/Audio/LivePlaybackController.swift` — see whether `AVAudioSession.sharedInstance().setCategory(.playback, ...)` is called
- `App/AppBootstrap.swift` — see when `LivePlaybackController` starts

**Steps:**

- [ ] **Step 1: Read the three files**

- [ ] **Step 2: Decide AVAudioSession ownership**

If `setCategory(.playback)` is already invoked inside swift-sheet-music or LivePlaybackController, do nothing. Otherwise, add:

```swift
// App/AppBootstrap.swift — inside init() after env var reads
import AVFoundation
try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [])
try? AVAudioSession.sharedInstance().setActive(true)
```

This must run regardless of playback state — PiP demands an active audio session to keep the app alive in background.

- [ ] **Step 3: Commit (only if Step 2 produced a code change)**

```bash
git add App/AppBootstrap.swift
git commit -m "Bootstrap AVAudioSession .playback for PiP background"
```

---

### Task 1: Skeleton `ScorePiPFrameRenderer`

**Files:**
- Create: `Packages/Features/Reader/Sources/Reader/PiP/ScorePiPFrameRenderer.swift`

Renderer responsibility: given a `Score`, `staffSize`, `playbackCursor`, and target `CGSize` in pixels, produce a `CVPixelBuffer` containing the horizontal score rendered at that size. Holds a long-lived `UIHostingController<HorizontalScoreContainer>` keyed on `Score` identity to avoid rebuilding the SwiftUI tree per frame.

- [ ] **Step 1: Write the file**

```swift
import AVFoundation
import CoreVideo
import SheetMusicCore
import SwiftUI
import UIKit

/// Renders a frame of the horizontal score to a `CVPixelBuffer` pulled
/// from a reusable pool. The pool is sized to a single buffer in flight
/// (PiP only consumes one at a time at this frame rate) plus one for
/// the renderer's working copy.
@MainActor
final class ScorePiPFrameRenderer {
    private let pixelSize: CGSize
    private let pool: CVPixelBufferPool
    private let hostingController: UIHostingController<PiPScoreContent>
    private var lastCursorTickHash: Int = -1

    init(score: Score, staffSize: CGFloat, pixelSize: CGSize) throws {
        self.pixelSize = pixelSize
        self.pool = try Self.makePool(size: pixelSize)

        let content = PiPScoreContent(
            score: score,
            staffSize: staffSize,
            playbackCursor: nil,
        )
        let hc = UIHostingController(rootView: content)
        hc.view.backgroundColor = .systemBackground
        hc.view.frame = CGRect(origin: .zero, size: pixelSize)
        hc.view.bounds = CGRect(origin: .zero, size: pixelSize)
        self._disableSafeAreaIfPossible(hc)
        self.hostingController = hc
    }

    /// Update the cursor and produce a new pixel buffer. Returns `nil`
    /// only when buffer allocation fails (pool exhausted).
    func renderFrame(playbackCursor: ScoreCursor?) -> CVPixelBuffer? {
        hostingController.rootView = PiPScoreContent(
            score: hostingController.rootView.score,
            staffSize: hostingController.rootView.staffSize,
            playbackCursor: playbackCursor,
        )
        hostingController.view.setNeedsLayout()
        hostingController.view.layoutIfNeeded()

        var maybeBuffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &maybeBuffer) == kCVReturnSuccess,
              let buffer = maybeBuffer
        else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue
            | CGBitmapInfo.byteOrder32Little.rawValue

        guard let ctx = CGContext(
            data: base,
            width: Int(pixelSize.width),
            height: Int(pixelSize.height),
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo,
        ) else { return nil }

        hostingController.view.layer.render(in: ctx)
        return buffer
    }

    private static func makePool(size: CGSize) throws -> CVPixelBufferPool {
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(size.width),
            kCVPixelBufferHeightKey as String: Int(size.height),
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as CFDictionary,
        ]
        var pool: CVPixelBufferPool?
        let status = CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &pool)
        guard status == kCVReturnSuccess, let pool else {
            throw NSError(
                domain: "ScorePiPFrameRenderer",
                code: Int(status),
                userInfo: [NSLocalizedDescriptionKey: "Failed to create CVPixelBufferPool"],
            )
        }
        return pool
    }

    private func _disableSafeAreaIfPossible(_ hc: UIHostingController<some View>) {
        // The hosting controller is off-screen — its safe area would be the
        // device's, not the PiP window's. Disable so the score draws edge to edge.
        if #available(iOS 16.4, *) {
            hc.safeAreaRegions = []
        }
    }
}

/// Lightweight wrapper around `HorizontalScoreContainer` for off-screen
/// rendering. Does *not* take the Reader view model — PiP is a one-way
/// display, so tap-to-seek and auto-scroll are intentionally inactive.
private struct PiPScoreContent: View {
    let score: Score
    let staffSize: CGFloat
    let playbackCursor: ScoreCursor?

    var body: some View {
        // Reuse the SheetMusicUI ScoreView directly rather than
        // HorizontalScoreContainer — the container's tap gesture +
        // auto-scroll plumbing isn't useful off-screen, and rebuilding
        // its `.task(id:)` layout per frame would be wasteful.
        // Layout once via LayoutEngine at the target width.
        PiPScoreCanvas(
            score: score,
            staffSize: staffSize,
            playbackCursor: playbackCursor,
        )
    }
}
```

Note: `PiPScoreCanvas` is implemented in Task 2. We stage the renderer first so the type lines up, then fill in the canvas.

- [ ] **Step 2: Confirm compile error is the only error**

Run: `swift build --package-path Packages/Features/Reader 2>&1 | tail -20`
Expected: error referencing missing `PiPScoreCanvas`. No other errors.

- [ ] **Step 3: Commit**

```bash
git add Packages/Features/Reader/Sources/Reader/PiP/ScorePiPFrameRenderer.swift
git commit -m "Skeleton ScorePiPFrameRenderer (PiP frame production)"
```

---

### Task 2: `PiPScoreCanvas` — the off-screen score view

**Files:**
- Create: `Packages/Features/Reader/Sources/Reader/PiP/PiPScoreCanvas.swift`

This view lays the score out once (per score change) using `LayoutEngine.naturalContentWidth(…)` + `LayoutEngine.layout(…)` and renders a horizontal strip of measures around the playback cursor. Tap gestures and scroll wrappers are intentionally absent.

- [ ] **Step 1: Write the file**

```swift
import SheetMusicCore
import SheetMusicLayout
import SheetMusicUI
import SwiftUI

/// Off-screen layout of a horizontal score for PiP rendering. Uses the
/// same `LayoutEngine` calls as `HorizontalScoreContainer`, but skips
/// the ScrollView, tap-to-seek, auto-scroll, and overlay markers —
/// PiP is purely a read-only display.
struct PiPScoreCanvas: View {
    let score: Score
    let staffSize: CGFloat
    let playbackCursor: ScoreCursor?

    var body: some View {
        let opts = ScoreViewOptions(
            staffSize: staffSize, systemGap: staffSize * 1.25,
            wrapToViewWidth: false, includeTitleFrame: false,
            breakPolicy: .ignoreAll,
            showBreakIndicators: false,
        )
        let naturalWidth = LayoutEngine.naturalContentWidth(score: score, options: opts)
        let document = LayoutEngine.layout(score: score, options: opts, availableWidth: naturalWidth)
        ScoreView(
            document: document, score: score, options: opts,
            playbackCursor: playbackCursor,
            playbackCursorColor: .accentColor,
        )
        // Horizontally offset so the cursor stays roughly centered in
        // the PiP window. Done as a transform on the rendered view rather
        // than ScrollView so off-screen rendering produces deterministic
        // pixels.
        .offset(x: cursorOffset(document: document))
    }

    private func cursorOffset(document: LayoutDocument) -> CGFloat {
        guard let cursor = playbackCursor else { return 0 }
        // measureFrame.minX inside the layout document, shifted so the
        // measure's leading edge sits a third of the way across the PiP
        // window. The hosting controller's width drives "where 1/3 is".
        let frame = document.frame(forMeasure: cursor.measureIndex) ?? .zero
        return -frame.minX + 80  // 80pt leading inset; tune empirically
    }
}
```

**Note for implementer:** `LayoutDocument.frame(forMeasure:)` is illustrative — the real API in swift-sheet-music may have a different name. Grep `Packages/Sources/.../LayoutDocument.swift` (in `.build/checkouts/swift-sheet-music`) at implementation time and substitute the correct lookup. If no per-measure frame is exposed, fall back to scrolling the entire `ScoreView` with `.scrollPosition()` inside an offscreen `ScrollView` — slower but always available.

- [ ] **Step 2: Run a quick package build**

Run: `swift build --package-path Packages/Features/Reader 2>&1 | tail -20`
Expected: PiP files compile, only references to AVKit-related Task 3 / 4 missing.

- [ ] **Step 3: Commit**

```bash
git add Packages/Features/Reader/Sources/Reader/PiP/PiPScoreCanvas.swift
git commit -m "PiPScoreCanvas — off-screen horizontal score for PiP"
```

---

### Task 3: Renderer snapshot test

**Files:**
- Create: `Packages/Features/Reader/Tests/ReaderTests/PiP/ScorePiPFrameRendererTests.swift`

Snapshot-style test: render a known Score at a fixed size, confirm the pixel buffer is non-nil, has expected dimensions, and is not entirely background-colored (i.e. something was drawn).

- [ ] **Step 1: Write the failing test**

```swift
import CoreVideo
import SheetMusicCore
import Testing
@testable import Reader

@MainActor
struct ScorePiPFrameRendererTests {
    @Test func rendersNonEmptyBufferForLoadedScore() throws {
        let score = sampleScore()
        let renderer = try ScorePiPFrameRenderer(
            score: score, staffSize: 14,
            pixelSize: CGSize(width: 600, height: 200),
        )
        let buffer = try #require(renderer.renderFrame(playbackCursor: nil))
        #expect(CVPixelBufferGetWidth(buffer) == 600)
        #expect(CVPixelBufferGetHeight(buffer) == 200)
        #expect(!isAllBackground(buffer))
    }

    /// True iff every pixel is plain background — used to confirm the
    /// hosting controller actually drew the score.
    private func isAllBackground(_ buffer: CVPixelBuffer) -> Bool {
        // Sample 256 random pixels; if any has non-background color,
        // the score drew. We don't bit-compare against a golden image
        // because hosting-controller rendering is platform-specific
        // and golden snapshots are brittle here.
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return true }
        let row = CVPixelBufferGetBytesPerRow(buffer)
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        for _ in 0..<256 {
            let x = Int.random(in: 0..<width)
            let y = Int.random(in: 0..<height)
            let i = y * row + x * 4
            // BGRA32; check for any non-white pixel
            if bytes[i] < 250 || bytes[i + 1] < 250 || bytes[i + 2] < 250 {
                return false
            }
        }
        return true
    }

    private func sampleScore() -> Score {
        // Borrow PreviewSupport's fixture for a known-good Score.
        ReaderPreviewSupport.sampleScore()
    }
}
```

- [ ] **Step 2: Run and verify failure**

Run: `cd Packages/Features/Reader && swift test --filter ScorePiPFrameRendererTests 2>&1 | tail -20`
Expected: build fails because `ReaderPreviewSupport.sampleScore()` may not be accessible from tests. Adjust to the actual preview-support entry point (grep `PreviewSupport.swift`).

- [ ] **Step 3: Make the test pass by either fixing the fixture access or pivoting to a hand-built Score**

Run: same `swift test` command.
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add Packages/Features/Reader/Tests/ReaderTests/PiP/ScorePiPFrameRendererTests.swift
git commit -m "Snapshot test for ScorePiPFrameRenderer"
```

---

### Task 4: `ScorePiPPlaybackDelegate` — AVKit-facing protocol object

**Files:**
- Create: `Packages/Features/Reader/Sources/Reader/PiP/ScorePiPPlaybackDelegate.swift`

`AVPictureInPictureSampleBufferPlaybackDelegate` is required by `AVPictureInPictureController` even though we never pause/seek through PiP. Implement the minimum: report we're "always playing" (so the system controls show the right state), reject seeks, and accept the rate-change callback as a no-op.

- [ ] **Step 1: Write the file**

```swift
import AVFoundation
import AVKit
import CoreMedia
import Foundation

@MainActor
final class ScorePiPPlaybackDelegate: NSObject, AVPictureInPictureSampleBufferPlaybackDelegate {
    /// Owner reads this to decide whether to keep pushing frames. Driven
    /// by AVKit via setPlaying / didTransitionTo callbacks. We mirror the
    /// app's actual playback state into the system controls by writing
    /// this from outside.
    var isPlaying: Bool = true

    func pictureInPictureController(
        _ controller: AVPictureInPictureController,
        setPlaying playing: Bool,
    ) {
        isPlaying = playing
        // We do not forward this to the app's playback engine — PiP is
        // display-only by design. The user toggles play/pause in the
        // app's chrome, not from the PiP overlay.
    }

    func pictureInPictureControllerTimeRangeForPlayback(
        _ controller: AVPictureInPictureController,
    ) -> CMTimeRange {
        // Reporting `positiveInfinity` is the AVKit-documented way to
        // say "this is a live source with no timeline" — hides the
        // seek scrubber from the PiP chrome.
        CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
    }

    func pictureInPictureControllerIsPlaybackPaused(
        _ controller: AVPictureInPictureController,
    ) -> Bool {
        !isPlaying
    }

    func pictureInPictureController(
        _ controller: AVPictureInPictureController,
        didTransitionToRenderSize newRenderSize: CMVideoDimensions,
    ) {
        // PiP window resize. We render at a fixed aspect ratio, so
        // ignore — AVKit will letterbox automatically. If we later want
        // crisp rendering at the new size, this is where we'd rebuild
        // the renderer's pool. Not in scope for v1.
    }

    func pictureInPictureController(
        _ controller: AVPictureInPictureController,
        skipByInterval skipInterval: CMTime,
        completion completionHandler: @escaping () -> Void,
    ) {
        // No-op: time scrubber is hidden anyway.
        completionHandler()
    }
}
```

- [ ] **Step 2: Build**

Run: `swift build --package-path Packages/Features/Reader 2>&1 | tail -10`
Expected: success.

- [ ] **Step 3: Commit**

```bash
git add Packages/Features/Reader/Sources/Reader/PiP/ScorePiPPlaybackDelegate.swift
git commit -m "ScorePiPPlaybackDelegate (display-only AVKit adapter)"
```

---

### Task 5: `ScorePiPCoordinator` — lifecycle + frame pump

**Files:**
- Create: `Packages/Features/Reader/Sources/Reader/PiP/ScorePiPCoordinator.swift`

Owns:
- `AVSampleBufferDisplayLayer` (passed in by the host view)
- `AVPictureInPictureController` built from that layer
- `ScorePiPFrameRenderer`
- `ScorePiPPlaybackDelegate`
- `CADisplayLink` throttled to 20 fps

API:
- `attach(displayLayer:)`
- `start(score:, staffSize:, playbackCursor:)` → kicks PiP + pump
- `stop()` → tears down PiP + pump
- `updatePlaybackCursor(_:)` → next pump tick uses this cursor

- [ ] **Step 1: Write the file**

```swift
import AVFoundation
import AVKit
import CoreMedia
import QuartzCore
import SheetMusicCore
import UIKit

@MainActor
final class ScorePiPCoordinator: NSObject {
    static var isSupported: Bool { AVPictureInPictureController.isPictureInPictureSupported() }

    private var displayLayer: AVSampleBufferDisplayLayer?
    private var pipController: AVPictureInPictureController?
    private var renderer: ScorePiPFrameRenderer?
    private let delegate = ScorePiPPlaybackDelegate()
    private var displayLink: CADisplayLink?

    private var currentCursor: ScoreCursor?
    private var lastEnqueuedCursorTickHash: Int?

    private let pixelSize = CGSize(width: 1280, height: 360)  // ~16:4.5 landscape
    private let framesPerSecond = 20

    func attach(displayLayer: AVSampleBufferDisplayLayer) {
        self.displayLayer = displayLayer
    }

    func start(score: Score, staffSize: CGFloat, playbackCursor: ScoreCursor?) throws {
        guard let displayLayer else {
            throw NSError(domain: "ScorePiPCoordinator", code: 1)
        }
        renderer = try ScorePiPFrameRenderer(
            score: score, staffSize: staffSize, pixelSize: pixelSize,
        )
        currentCursor = playbackCursor

        let source = AVPictureInPictureController.ContentSource(
            sampleBufferDisplayLayer: displayLayer,
            playbackDelegate: delegate,
        )
        let controller = AVPictureInPictureController(contentSource: source)
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        controller.delegate = self
        pipController = controller

        startPump()
        // Enqueue at least one frame so AVKit has something to display
        // when the user (or auto-start) raises the PiP window.
        pumpTick()

        if controller.isPictureInPicturePossible {
            controller.startPictureInPicture()
        }
    }

    func stop() {
        pipController?.stopPictureInPicture()
        pipController = nil
        stopPump()
        renderer = nil
        displayLayer?.flush()
    }

    func updatePlaybackCursor(_ cursor: ScoreCursor?) {
        currentCursor = cursor
    }

    private func startPump() {
        let link = CADisplayLink(target: self, selector: #selector(pumpTickObjC))
        link.preferredFramesPerSecond = framesPerSecond
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopPump() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func pumpTickObjC() { pumpTick() }

    private func pumpTick() {
        guard let renderer, let displayLayer else { return }
        // Skip redraw if cursor hasn't moved since last frame — saves
        // ~95% of CPU in static states (paused, tuner-mode without
        // playback).
        let hash = currentCursor.map(\.absoluteTick) ?? -1
        if hash == lastEnqueuedCursorTickHash {
            // Still need to keep enqueueing periodically so AVKit
            // doesn't stall — push a duplicate every 1s.
            if displayLayer.isReadyForMoreMediaData,
               (Int.random(in: 0..<framesPerSecond) == 0) {
                if let buf = renderer.renderFrame(playbackCursor: currentCursor) {
                    enqueue(buf)
                }
            }
            return
        }
        lastEnqueuedCursorTickHash = hash
        guard displayLayer.isReadyForMoreMediaData,
              let buf = renderer.renderFrame(playbackCursor: currentCursor)
        else { return }
        enqueue(buf)
    }

    private func enqueue(_ pixelBuffer: CVPixelBuffer) {
        guard let displayLayer else { return }
        var fmt: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: nil, imageBuffer: pixelBuffer, formatDescriptionOut: &fmt,
        )
        guard let fmt else { return }

        let now = CMClockGetTime(CMClockGetHostTimeClock())
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(framesPerSecond)),
            presentationTimeStamp: now,
            decodeTimeStamp: .invalid,
        )

        var sample: CMSampleBuffer?
        let status = CMSampleBufferCreateForImageBuffer(
            allocator: nil,
            imageBuffer: pixelBuffer,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: fmt,
            sampleTiming: &timing,
            sampleBufferOut: &sample,
        )
        guard status == noErr, let sample else { return }
        displayLayer.enqueue(sample)
    }
}

extension ScorePiPCoordinator: AVPictureInPictureControllerDelegate {
    func pictureInPictureControllerDidStopPictureInPicture(
        _ controller: AVPictureInPictureController,
    ) {
        // User dismissed the PiP window — stop pumping frames.
        stopPump()
    }
}
```

`ScoreCursor.absoluteTick` is illustrative — substitute the real "monotonic-ish identifier" for a cursor position. If not available, hash `(measureIndex, tickInMeasure, staffIndex)`.

- [ ] **Step 2: Build**

Run: `swift build --package-path Packages/Features/Reader 2>&1 | tail -10`
Expected: success.

- [ ] **Step 3: Commit**

```bash
git add Packages/Features/Reader/Sources/Reader/PiP/ScorePiPCoordinator.swift
git commit -m "ScorePiPCoordinator (PiP lifecycle + 20fps frame pump)"
```

---

### Task 6: `ScorePiPHostView` — SwiftUI bridge

**Files:**
- Create: `Packages/Features/Reader/Sources/Reader/PiP/ScorePiPHostView.swift`

A zero-size `UIViewRepresentable` whose backing `UIView` hosts the `AVSampleBufferDisplayLayer` as a sublayer. AVKit needs the layer to be inside a view hierarchy attached to a window — that's why we install this in the Reader root.

- [ ] **Step 1: Write the file**

```swift
import AVFoundation
import SheetMusicCore
import SwiftUI
import UIKit

/// Hosts the `AVSampleBufferDisplayLayer` that backs PiP. Installed by
/// `ReaderRootScreen` as a zero-size overlay so the layer is in a
/// window-attached view tree (an AVKit requirement) but invisible
/// to the user.
struct ScorePiPHostView: UIViewRepresentable {
    let coordinator: ScorePiPCoordinator

    func makeUIView(context: Context) -> ScorePiPContainerView {
        let view = ScorePiPContainerView()
        coordinator.attach(displayLayer: view.displayLayer)
        return view
    }

    func updateUIView(_ uiView: ScorePiPContainerView, context: Context) {
        // No-op — the coordinator drives the layer directly.
    }
}

final class ScorePiPContainerView: UIView {
    let displayLayer = AVSampleBufferDisplayLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        displayLayer.videoGravity = .resizeAspect
        displayLayer.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
        layer.addSublayer(displayLayer)
        isUserInteractionEnabled = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}
```

- [ ] **Step 2: Build**

Run: `swift build --package-path Packages/Features/Reader 2>&1 | tail -10`
Expected: success.

- [ ] **Step 3: Commit**

```bash
git add Packages/Features/Reader/Sources/Reader/PiP/ScorePiPHostView.swift
git commit -m "ScorePiPHostView (SwiftUI bridge for PiP display layer)"
```

---

### Task 7: ViewModel + toolbar wiring

**Files:**
- Modify: `Packages/Features/Reader/Sources/Reader/ReaderViewModel.swift`
- Modify: `Packages/Features/Reader/Sources/Reader/Screens/ReaderRootScreen.swift`
- Modify: `Packages/Features/Reader/Sources/Reader/Screens/ReaderToolbar.swift`

ViewModel exposes:
- `isPiPSupported: Bool` (computed via `ScorePiPCoordinator.isSupported`)
- `isPiPActive: Bool` (mirrors coordinator state via delegate callbacks)
- `togglePiP()` method
- An owned `ScorePiPCoordinator` instance, created lazily

Root screen installs `ScorePiPHostView(coordinator:)` as a 1pt-square overlay, hidden offscreen.

Toolbar adds a PiP toggle button — `pip.fill` SF symbol — gated on `isPiPSupported` and the score being loaded.

- [ ] **Step 1: ViewModel additions**

In `ReaderViewModel.swift`, add (locate the section near `isPlaybackInspectorPresented` for ordering):

```swift
@MainActor
public var isPiPSupported: Bool { ScorePiPCoordinator.isSupported }

@MainActor
public var isPiPActive: Bool = false

@MainActor
public let pipCoordinator = ScorePiPCoordinator()

@MainActor
public func togglePiP() {
    guard case let .loaded(score) = loadState else { return }
    if isPiPActive {
        pipCoordinator.stop()
        isPiPActive = false
    } else {
        do {
            try pipCoordinator.start(
                score: score,
                staffSize: preferences.staffSize,
                playbackCursor: playbackCursor,
            )
            isPiPActive = true
        } catch {
            // Surface no UI for v1 — failures here mean device doesn't
            // support custom PiP; the button is already gated on
            // isPiPSupported, so this branch is unreachable in practice.
        }
    }
}
```

Also: in the playback-cursor observation block (already exists around line 140), call:

```swift
pipCoordinator.updatePlaybackCursor(playbackCursor)
```

after `playbackCursor = translateCursorForHiddenStaves(value)`.

- [ ] **Step 2: Toolbar button**

In `ReaderToolbar.swift`, inside `loadedActions(score:)`, before the `inspectorButtons(score:)` call, insert:

```swift
if viewModel.isPiPSupported {
    overlayButton(
        systemImage: viewModel.isPiPActive ? "pip.exit" : "pip.enter",
        label: Text(
            viewModel.isPiPActive
                ? "reader.toolbar.exitPiP"
                : "reader.toolbar.enterPiP",
            bundle: .module,
        ),
    ) {
        viewModel.togglePiP()
    }
    .glassEffect(.regular.interactive())
}
```

- [ ] **Step 3: Add the two localized strings**

Edit `Packages/Features/Reader/Sources/Reader/Resources/Localizable.xcstrings` (path may differ — grep for `reader.toolbar.play` to confirm):

Add entries `reader.toolbar.enterPiP` → "Show in Picture in Picture" and `reader.toolbar.exitPiP` → "Hide Picture in Picture", following the module's [localization key scheme](../engineering/module-architecture.md) (`module.feature.thing` — see memory `project_localization_key_scheme.md`).

- [ ] **Step 4: Root screen install the host view**

In `ReaderRootScreen.swift`, inside the outer `ZStack`, add (anywhere in the stack — it's invisible):

```swift
ScorePiPHostView(coordinator: viewModel.pipCoordinator)
    .frame(width: 1, height: 1)
    .opacity(0)
    .allowsHitTesting(false)
```

- [ ] **Step 5: Build the app**

Run: `xcodebuild -project Folino.xcodeproj -scheme Folino -destination 'platform=iOS Simulator,name=iPhone 16' -skipPackagePluginValidation build 2>&1 | tail -15`
Expected: BUILD SUCCEEDED.

- [ ] **Step 6: Commit**

```bash
git add Packages/Features/Reader/Sources/Reader/ReaderViewModel.swift \
        Packages/Features/Reader/Sources/Reader/Screens/ReaderRootScreen.swift \
        Packages/Features/Reader/Sources/Reader/Screens/ReaderToolbar.swift \
        Packages/Features/Reader/Sources/Reader/Resources/Localizable.xcstrings
git commit -m "Wire PiP toggle into Reader toolbar"
```

---

### Task 8: Manual verification

**Files:** none modified.

PiP cannot be exercised reliably from unit tests — verify by hand.

- [ ] **Step 1: Run on iPhone 16 simulator**

Run: build + install + launch via `xcodebuild` + `xcrun simctl`.

- [ ] **Step 2: Open a loaded score, switch to horizontal mode, tap the PiP button**

Expected: small floating window in the simulator showing the score with the cursor visible.

- [ ] **Step 3: Start playback, watch cursor advance in the PiP window**

Expected: cursor visibly moves at the same chord boundaries as the main view. ~20fps stutter is acceptable; if the cursor stalls completely or the window goes black, the frame pump is wedged.

- [ ] **Step 4: Background the app (Home gesture)**

Expected: PiP window persists in the simulator's notification center / lock-screen analogue; cursor continues advancing.

- [ ] **Step 5: Tap the PiP button again**

Expected: PiP window dismisses, score returns to fullscreen.

- [ ] **Step 6: Write findings**

Append a brief "manual verification" section to the bottom of this plan with observations (cursor latency, jank, simulator vs device discrepancies). This is the artifact that informs whether to ship or iterate.

---

## Self-Review Notes

- **Spec coverage:** Plan covers the requested capability (PiP of horizontal score, ~20fps, no new screen).
- **Audio session:** Task 0 is a safety check, not an assumed fix — may be a no-op.
- **Layout offset:** Task 2's `cursorOffset` math is best-effort. If swift-sheet-music doesn't expose measure frames, the implementer should pivot to a `ScrollView` + programmatic scroll position inside the off-screen hosting controller.
- **Test depth:** Snapshot test in Task 3 verifies the renderer produces *something*. Full PiP flow is manual (Task 8). This is deliberate — AVKit's runtime isn't economically mockable.
- **Lifecycle gaps:** If the user closes the score / navigates away while PiP is active, we don't currently force-stop. Add in v2 if needed — for the first prototype the user can dismiss the PiP window themselves.
- **No tuner-specific feature:** The tuner use case drove the requirement, but no in-app tuner is implemented; the user runs a separate app.
