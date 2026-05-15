import ImportExportAppGroup
import ImportExportShareUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import UtilityCore

final class ShareViewController: UIViewController {
    private var hostingController: UIHostingController<ShareRootView>?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        guard let container = AppGroupPaths.container() else {
            presentFatalError("App Group container unavailable.")
            return
        }

        let session = ShareSession(appGroupContainer: container, clock: SystemClock())
        let items = collectItemProviders()

        let root = ShareRootView(session: session, items: items) { [weak self] completion in
            self?.handleCompletion(completion)
        }

        let host = UIHostingController(rootView: root)
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        host.didMove(toParent: self)
        hostingController = host
    }

    private func collectItemProviders() -> [NSItemProvider] {
        guard let extensionItems = extensionContext?.inputItems as? [NSExtensionItem] else {
            return []
        }
        return extensionItems.flatMap { $0.attachments ?? [] }
    }

    private func handleCompletion(_ completion: ShareCompletion) {
        switch completion.outcome {
        case .cancelled:
            extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
        case let .submitted(openURL):
            extensionContext?.completeRequest(returningItems: nil) { _ in
                self.openMainApp(url: openURL)
            }
        }
    }

    /// Walks the responder chain to find a `UIApplication` and invokes its
    /// `open(_:options:completionHandler:)`. Best-effort: if the chain doesn't
    /// reach a `UIApplication`, the drain-on-launch fallback in the main app
    /// still picks up the token.
    private func openMainApp(url: URL) {
        var responder: UIResponder? = self
        while let current = responder {
            if let application = current as? UIApplication {
                application.open(url, options: [:], completionHandler: nil)
                return
            }
            responder = current.next
        }
    }

    private func presentFatalError(_ message: String) {
        let alert = UIAlertController(title: "Folino", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in
            self.extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
        })
        present(alert, animated: true)
    }
}
