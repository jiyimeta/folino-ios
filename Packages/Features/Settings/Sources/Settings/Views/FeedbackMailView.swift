import DeviceKit
import Foundation
import MessageUI
import SwiftUI

enum FeedbackMailComposeResult: Equatable {
    case cancelled
    case saved
    case sent
    case failed
}

struct FeedbackMailView: UIViewControllerRepresentable {
    @Environment(\.dismiss) private var dismiss
    @Binding var result: FeedbackMailComposeResult?

    static var canSendMail: Bool {
        MFMailComposeViewController.canSendMail()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(dismiss: dismiss, result: $result)
    }

    func makeUIViewController(context: Context) -> MFMailComposeViewController {
        let controller = MFMailComposeViewController()
        controller.mailComposeDelegate = context.coordinator
        controller.setSubject("folino Feedback")
        controller.setToRecipients([FeedbackMailConfiguration.recipient])
        controller.setMessageBody(FeedbackMailConfiguration.messageBody, isHTML: false)
        return controller
    }

    func updateUIViewController(_: MFMailComposeViewController, context _: Context) {}

    final class Coordinator: NSObject, MFMailComposeViewControllerDelegate {
        private let dismiss: DismissAction
        @Binding private var result: FeedbackMailComposeResult?

        init(dismiss: DismissAction, result: Binding<FeedbackMailComposeResult?>) {
            self.dismiss = dismiss
            _result = result
        }

        func mailComposeController(
            _: MFMailComposeViewController,
            didFinishWith result: MFMailComposeResult,
            error _: Error?,
        ) {
            self.result = switch result {
            case .cancelled: .cancelled
            case .saved: .saved
            case .sent: .sent
            case .failed: .failed
            @unknown default: .failed
            }
            // `MFMailComposeViewControllerDelegate` callbacks arrive on the main thread, but the requirement is
            // nonisolated, so assume main-actor isolation to invoke the main-actor `DismissAction`. Bind `dismiss` to a
            // local first so the closure captures the (Sendable) action rather than `self`.
            let dismiss = dismiss
            MainActor.assumeIsolated { dismiss() }
        }
    }
}

private enum FeedbackMailConfiguration {
    static let recipient = "jiyi.meta@gmail.com"

    static var messageBody: String {
        """
        App Version: \(appVersion)
        OS: \(operatingSystemVersion)
        Device: \(deviceName)

        Feedback:
        """
    }

    private static var appVersion: String {
        let shortVersion =
            Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"
        let buildNumber = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "Unknown"
        return "\(shortVersion) (\(buildNumber))"
    }

    private static var operatingSystemVersion: String {
        ProcessInfo.processInfo.operatingSystemVersionString
    }

    private static var deviceName: String {
        Device.current.description
    }
}
