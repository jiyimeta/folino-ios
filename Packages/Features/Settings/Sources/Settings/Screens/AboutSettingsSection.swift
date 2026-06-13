import Domain
import SettingsLogic
import SwiftUI
import UtilityUI

/// The Settings sheet's about section: version history, third-party licenses, and the feedback-mail entry point. Owns
/// the feedback-mail presentation and result-alert `@State` so that flow is scoped here, alongside the button that
/// triggers it.
struct AboutSettingsSection<LicenseContent: View>: View {
    let versionHistoryLoader: any VersionHistoryLoader
    let onVersionHistoryViewed: @MainActor () -> Void
    let licenseContent: () -> LicenseContent

    @State private var isFeedbackMailPresented = false
    @State private var feedbackMailResult: FeedbackMailComposeResult?
    @State private var isMailSavedAlertPresented = false
    @State private var isMailFailedAlertPresented = false

    var body: some View {
        Section {
            NavigationLink {
                versionHistoryDestination
                    .navigationTitle(Text("settings.versionHistory.title", bundle: .module))
                    .navigationBarTitleDisplayMode(.inline)
            } label: {
                Label {
                    Text("settings.versionHistory.title", bundle: .module)
                } icon: {
                    Image(systemName: "clock.arrow.circlepath")
                }
            }

            NavigationLink {
                licenseContent()
                    .navigationTitle(Text("settings.about.licenses", bundle: .module))
                    .navigationBarTitleDisplayMode(.inline)
            } label: {
                Label {
                    Text("settings.about.licenses", bundle: .module)
                } icon: {
                    Image(systemName: "doc.text")
                }
            }

            Button {
                isFeedbackMailPresented = true
            } label: {
                Label {
                    Text("settings.about.sendFeedback", bundle: .module)
                } icon: {
                    Image(systemName: "envelope")
                }
            }
            .disabled(!FeedbackMailView.canSendMail)
        } header: {
            Text("settings.about.title", bundle: .module)
        }
        .sheet(isPresented: $isFeedbackMailPresented) {
            FeedbackMailView(result: $feedbackMailResult)
        }
        .alert(
            Text("settings.feedback.saved.title", bundle: .module),
            isPresented: $isMailSavedAlertPresented,
        ) {
            Button(role: .cancel) {} label: { L10n.Common.ok }
        }
        .alert(
            Text("settings.feedback.failed.title", bundle: .module),
            isPresented: $isMailFailedAlertPresented,
        ) {
            Button(role: .cancel) {} label: { L10n.Common.ok }
        }
        .onChange(of: feedbackMailResult) { _, newValue in
            switch newValue {
            case .saved:
                isMailSavedAlertPresented = true
            case .failed:
                isMailFailedAlertPresented = true
            case .cancelled, .sent, nil:
                break
            }
        }
    }

    @ViewBuilder
    private var versionHistoryDestination: some View {
        if let entries = try? versionHistoryLoader.load() {
            VersionHistoryScreen(
                viewModel: VersionHistoryViewModel(
                    entries: entries,
                    baseline: .zero,
                    isHistorySplit: false,
                ),
                onAppear: onVersionHistoryViewed,
            )
        } else {
            ContentUnavailableView {
                Label {
                    Text("settings.versionHistory.empty", bundle: .module)
                } icon: {
                    Image(systemName: "exclamationmark.triangle")
                }
            }
        }
    }
}
