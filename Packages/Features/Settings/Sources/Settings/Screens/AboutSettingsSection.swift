import Domain
import SettingsLogic
import SwiftUI
import UtilityUI

/// The Settings sheet's about section: version history, third-party licenses, and the feedback-mail entry point.
///
/// The mail flow itself is presented by `feedbackMailPresentation(isPresented:)` on the enclosing `Form`; this section
/// only flips the binding. A presentation modifier written here would be applied to every row of the section and the
/// composer would dismiss itself as soon as it opened.
struct AboutSettingsSection<LicenseContent: View>: View {
    let versionHistoryLoader: any VersionHistoryLoader
    let onVersionHistoryViewed: @MainActor () -> Void
    let licenseContent: () -> LicenseContent
    @Binding var isFeedbackMailPresented: Bool

    var body: some View {
        Section {
            NavigationLink {
                versionHistoryDestination
                    .navigationTitle(Text("settings.versionHistory.title", bundle: .module))
                    .inlineNavigationTitleCompat()
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
                    .inlineNavigationTitleCompat()
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
