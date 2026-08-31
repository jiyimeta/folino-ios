// PARITY(macos): the `UIViewRepresentable` host for `ScorePiPCoordinator`'s display layer — iOS/tvOS-only AVKit PiP,
//   see the marker on that file. `ReaderRootScreen` only mounts this when `ReaderPiPSession.isSupported`, which is
//   `false` on macOS.

#if os(iOS)
import AVFoundation
import SwiftUI
import UIKit

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
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
}
#endif
