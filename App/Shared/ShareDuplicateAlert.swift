import Domain
import SwiftUI
import UtilityUI

extension View {
    /// Attaches the share-extension duplicate-resolution alert. Presented once per duplicate file, sequentially, with
    /// the "Open" affordance suppressed for multi-file batches.
    func shareDuplicateAlert(resolver: ShareDuplicateResolver) -> some View {
        modifier(ShareDuplicateAlertModifier(resolver: resolver))
    }
}

private struct ShareDuplicateAlertModifier: ViewModifier {
    let resolver: ShareDuplicateResolver

    private var isPresented: Binding<Bool> {
        Binding(
            get: { resolver.currentPrompt != nil },
            set: { presented in
                if !presented {
                    resolver.respond(nil)
                }
            },
        )
    }

    func body(content: Content) -> some View {
        content.alert(
            Text("app.share.duplicate.title"),
            isPresented: isPresented,
            presenting: resolver.currentPrompt,
        ) { prompt in
            if !prompt.isMultiFile {
                Button {
                    resolver.respond(.openExisting(prompt.existing.id))
                } label: {
                    L10n.Common.open
                }
            }
            Button {
                resolver.respond(.importAsNew)
            } label: {
                Text("app.share.duplicate.keepBoth")
            }
            Button(role: .cancel) {
                resolver.respond(nil)
            } label: {
                L10n.Common.cancel
            }
        } message: { prompt in
            Text(String(
                localized: "app.share.duplicate.message",
                defaultValue: "\"\(prompt.existing.title)\" is already imported. What do you want to do?",
            ))
        }
    }
}
