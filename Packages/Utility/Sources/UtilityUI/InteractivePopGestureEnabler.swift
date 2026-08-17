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
        /// The delegate this coordinator temporarily replaced, enforcing the standard guards (no pop mid-transition,
        /// none at the root). Put back on teardown — leaving ours installed after this screen is gone would strip
        /// those guards from every other screen in the same stack.
        ///
        /// Held STRONGLY, with one exception: when the previous delegate IS the `UINavigationController` itself, it
        /// is kept weak instead (`previousNavigationController` below) — the navigation controller is already
        /// retained by the stack / window, so a second strong owner here buys nothing.
        ///
        /// The strong hold matters when two coordinators briefly overlap — e.g. SwiftUI building the replacement
        /// representable for an `.id(item.id)` detail swap before dismantling the old one. If coordinator B captured
        /// coordinator A as `previousDelegate` while only holding it weakly, A can be deallocated (nothing else
        /// retains a Coordinator once its own `dismantleUIViewController` has run, and `UIGestureRecognizer.delegate`
        /// is weak) before B's own `restore()` runs — B would then assign a deallocated reference, i.e. `nil`,
        /// leaving the stack with an unguarded interactive pop gesture that can wedge the navigation controller.
        /// `UIGestureRecognizer.delegate` being weak is exactly why holding the previous delegate strongly here
        /// creates no reference cycle back through it.
        private var previousDelegate: UIGestureRecognizerDelegate?
        private weak var previousNavigationController: UINavigationController?
        /// The deferred `install` work, kept so a render that lands right before a pop can't re-poison the delegate
        /// after `restore()` has already run — see `install(from:)`.
        private var pendingInstall: DispatchWorkItem?

        /// What `restore()` hands back: the strongly-held previous delegate, or the weakly-held navigation
        /// controller when that WAS the previous delegate — see `previousDelegate`'s doc comment.
        private var resolvedPreviousDelegate: UIGestureRecognizerDelegate? {
            // `UINavigationController` isn't declared to Swift as conforming to `UIGestureRecognizerDelegate` even
            // though it satisfies it at the Objective-C runtime level (that's how it got recorded as
            // `previousNavigationController` in the first place — see `install(from:)`), so the fallback needs an
            // explicit dynamic cast rather than a plain `??` unification.
            previousDelegate ?? (previousNavigationController as? UIGestureRecognizerDelegate)
        }

        func install(from controller: UIViewController) {
            pendingInstall?.cancel()
            // Deferred: the controller has no parent chain on the first layout pass. `updateUIViewController`
            // re-triggers this on every re-render, so a render just before a pop can leave a block queued that would
            // otherwise run AFTER `restore()` but before the popped controller detaches from its navigation
            // controller — `controller?.navigationController` still resolves in that window, which would silently
            // undo the restore. `restore()` cancels this work item, so a stale block is a no-op instead.
            let workItem = DispatchWorkItem { [weak self, weak controller] in
                guard let self, let navigation = controller?.navigationController else { return }
                navigationController = navigation
                guard let recognizer = navigation.interactivePopGestureRecognizer else { return }
                // Another coordinator (from an overlapping representable) is already installed — wait for IT to
                // restore rather than taking over now, which would leave two coordinators each recording the other
                // as `previousDelegate`. `updateUIViewController` re-runs this on every re-render, so installation
                // simply happens on the next pass once the other coordinator has cleaned up after itself.
                if let other = recognizer.delegate as? Coordinator, other !== self { return }
                if recognizer.delegate !== self {
                    if let navigationDelegate = recognizer.delegate as? UINavigationController {
                        previousNavigationController = navigationDelegate
                        previousDelegate = nil
                    } else {
                        previousDelegate = recognizer.delegate
                        previousNavigationController = nil
                    }
                }
                recognizer.delegate = self
                recognizer.isEnabled = true
            }
            pendingInstall = workItem
            DispatchQueue.main.async(execute: workItem)
        }

        func restore() {
            pendingInstall?.cancel()
            pendingInstall = nil
            guard let recognizer = navigationController?.interactivePopGestureRecognizer,
                  recognizer.delegate === self
            else { return }
            recognizer.delegate = resolvedPreviousDelegate
        }

        public func gestureRecognizerShouldBegin(_: UIGestureRecognizer) -> Bool {
            guard let navigationController else { return false }
            // UIKit's own delegate also refuses to begin during a transition; swiping mid-transition is a
            // documented route to a corrupted navigation bar, so this guard mirrors that rather than relying only on
            // there being more than one view controller on the stack.
            return navigationController.viewControllers.count > 1 && navigationController.transitionCoordinator == nil
        }
    }
}

extension View {
    /// Attach to a screen that hides the navigation bar but still wants edge-swipe back.
    public func restoresInteractivePopGesture() -> some View {
        background(InteractivePopGestureEnabler().frame(width: 0, height: 0))
    }
}
