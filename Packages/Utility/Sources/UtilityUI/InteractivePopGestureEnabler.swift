import SwiftUI
import UIKit

/// Restores the edge-swipe-back gesture on a screen that hides the navigation bar.
///
/// UIKit disables `interactivePopGestureRecognizer` when a view controller has no back button — reasonable, since
/// without one there would be no visible affordance for what the swipe does. A screen that draws its own back
/// control has the affordance and wants the gesture, so this reinstates it by supplying a delegate that allows the
/// gesture whenever there is something to pop.
///
/// No private API: it walks up from a hosted controller to its `navigationController` and sets a delegate. The
/// delegate is retained by this coordinator, because `UIGestureRecognizer.delegate` is weak.
public struct InteractivePopGestureEnabler: UIViewControllerRepresentable {
    public init() {}

    public func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    public func makeUIViewController(context: Context) -> UIViewController {
        let controller = UIViewController()
        controller.view.isUserInteractionEnabled = false
        context.coordinator.install(from: controller)
        return controller
    }

    public func updateUIViewController(_ controller: UIViewController, context: Context) {
        context.coordinator.install(from: controller)
    }

    public static func dismantleUIViewController(_: UIViewController, coordinator: Coordinator) {
        coordinator.restore()
    }

    public final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        private weak var navigationController: UINavigationController?
        /// The navigation controller's own delegate, which enforces the standard guards (no pop mid-transition, none
        /// at the root). Put back on teardown — leaving ours installed after this screen is gone would strip those
        /// guards from every other screen in the same stack.
        private weak var previousDelegate: UIGestureRecognizerDelegate?

        func install(from controller: UIViewController) {
            // Deferred: the controller has no parent chain on the first layout pass.
            DispatchQueue.main.async { [weak self, weak controller] in
                guard let self, let navigation = controller?.navigationController else { return }
                navigationController = navigation
                guard let recognizer = navigation.interactivePopGestureRecognizer else { return }
                if recognizer.delegate !== self { previousDelegate = recognizer.delegate }
                recognizer.delegate = self
                recognizer.isEnabled = true
            }
        }

        func restore() {
            guard let recognizer = navigationController?.interactivePopGestureRecognizer,
                  recognizer.delegate === self
            else { return }
            recognizer.delegate = previousDelegate
        }

        public func gestureRecognizerShouldBegin(_: UIGestureRecognizer) -> Bool {
            (navigationController?.viewControllers.count ?? 0) > 1
        }

        /// Lets the swipe coexist with the score's own pan/zoom gestures rather than cancelling them outright.
        public func gestureRecognizer(
            _: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith _: UIGestureRecognizer,
        ) -> Bool {
            false
        }
    }
}

extension View {
    /// Attach to a screen that hides the navigation bar but still wants edge-swipe back.
    public func restoresInteractivePopGesture() -> some View {
        background(InteractivePopGestureEnabler().frame(width: 0, height: 0))
    }
}
