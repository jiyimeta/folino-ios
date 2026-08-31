import Domain
import SettingsLogic
import SwiftUI

#if os(macOS)
import AppKit
#endif

/// Typed accessors for Settings-module localized strings that need to be resolved from outside the module (e.g. App
/// composition root). Routing through `LocalizedStringResource` with an explicit bundle URL ensures the lookup hits
/// Settings's resource bundle rather than the caller's `.module`.
public enum VersionHistoryStrings {
    public static var title: LocalizedStringResource {
        LocalizedStringResource(
            "settings.versionHistory.title",
            bundle: .atURL(Bundle.module.bundleURL),
        )
    }
}

public struct VersionHistoryScreen: View {
    private let viewModel: VersionHistoryViewModel
    @Environment(\.colorScheme) private var colorScheme
    private let onAppear: @MainActor () -> Void

    public init(viewModel: VersionHistoryViewModel, onAppear: @escaping @MainActor () -> Void = {}) {
        self.viewModel = viewModel
        self.onAppear = onAppear
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if viewModel.isHistorySplit {
                    splitBody
                } else {
                    entriesList(viewModel.recentChanges + viewModel.pastChanges)
                }
            }
            .padding()
        }
        .onAppear { onAppear() }
    }

    @ViewBuilder
    private var splitBody: some View {
        if !viewModel.recentChanges.isEmpty {
            sectionHeader("settings.versionHistory.recentUpdates")
            entriesList(viewModel.recentChanges)
        }
        if !viewModel.pastChanges.isEmpty {
            Divider()
            if viewModel.isPastChangesShown {
                sectionHeader("settings.versionHistory.pastChanges")
                entriesList(viewModel.pastChanges)
            } else {
                Button {
                    viewModel.showMoreButtonDidTap()
                } label: {
                    Text("settings.versionHistory.showMore", bundle: .module)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private func sectionHeader(_ key: LocalizedStringKey) -> some View {
        Text(key, bundle: .module)
            .font(.title3.bold())
    }

    private func entriesList(_ entries: [VersionHistoryEntry]) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(entries) { entry in
                entryRow(entry)
            }
        }
    }

    private func entryRow(_ entry: VersionHistoryEntry) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(entry.version.description)
                .font(.headline)
            ForEach(Array(entry.descriptions.enumerated()), id: \.offset) { _, line in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("•")
                    Text(line)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(rowBackground(for: entry.version), in: RoundedRectangle(cornerRadius: 10))
    }

    // PARITY(macos): version-history row background — iOS uses the grouped-list "secondary system background" gray,
    //   a raised card on top of the grouped-list base. macOS substitutes `.underPageBackgroundColor`, a provisional
    //   pick until Reader's own port settles what a Mac grouped surface should read as.
    private func rowBackground(for version: AppVersion) -> Color {
        let isMajorRelease = version.minor == 0 && version.patch == 0
        guard isMajorRelease else {
            #if os(iOS)
            return Color(.secondarySystemBackground)
            #else
            return Color(nsColor: .underPageBackgroundColor)
            #endif
        }
        return colorScheme == .dark
            ? Color.yellow.opacity(0.18)
            : Color.blue.opacity(0.12)
    }
}

#Preview("Settings push (flat)") {
    let entries = [
        VersionHistoryEntry(
            version: AppVersion(1, 1, 1),
            descriptions: ["Fixed an import error", "Improved playback"],
        ),
        VersionHistoryEntry(
            version: AppVersion(1, 1, 0),
            descriptions: ["Added MIDI import", "Improved score recognition"],
        ),
        VersionHistoryEntry(version: AppVersion(1, 0, 0), descriptions: []),
    ]
    return VersionHistoryScreen(
        viewModel: VersionHistoryViewModel(entries: entries, baseline: .zero, isHistorySplit: false),
    )
}

#Preview("Auto-sheet (split, collapsed)") {
    let entries = [
        VersionHistoryEntry(
            version: AppVersion(1, 1, 1),
            descriptions: ["Fixed an import error", "Improved playback"],
        ),
        VersionHistoryEntry(
            version: AppVersion(1, 1, 0),
            descriptions: ["Added MIDI import"],
        ),
        VersionHistoryEntry(version: AppVersion(1, 0, 0), descriptions: []),
    ]
    return VersionHistoryScreen(
        viewModel: VersionHistoryViewModel(
            entries: entries, baseline: AppVersion(1, 1, 0), isHistorySplit: true,
        ),
    )
}
