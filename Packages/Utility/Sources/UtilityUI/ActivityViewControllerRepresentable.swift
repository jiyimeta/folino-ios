#if os(iOS)
import SwiftUI
import UIKit

// PARITY(macos): system share sheet — macOS needs an NSSharingServicePicker equivalent, wired into
// ScoreShareTarget's call sites.

/// Bridges `UIActivityViewController` (the system share sheet) into SwiftUI. Use via `.sheet {
/// ActivityViewControllerRepresentable(items: [...]) }`.
public struct ActivityViewControllerRepresentable: UIViewControllerRepresentable {
    private let items: [Any]
    private let activities: [UIActivity]?

    public init(items: [Any], activities: [UIActivity]? = nil) {
        self.items = items
        self.activities = activities
    }

    public func makeUIViewController(context _: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: activities)
    }

    public func updateUIViewController(_: UIActivityViewController, context _: Context) {}
}
#endif
