#if DEBUG
import Reader
import SwiftUI

/// The DEBUG-only entry point into `DebugMenuSheet`, and the sheet itself.
///
/// Button and presentation are deliberately apart. A `ToolbarItem` button that carries a presentation modifier cannot
/// be turned into a menu row, so the bar's overflow menu ends up empty and unopenable (the same trap the Reader's
/// inspector buttons fell into) — the button stays bare and the screen owns the sheet.
///
/// The button is handed to `LibraryRootScreen` through its `leadingToolbarItem` seam rather than attached with a
/// `.toolbar` of its own: that screen owns its `NavigationStack`, and a `.toolbar` stated OUTSIDE it has no navigation
/// container to resolve against, so the item is silently dropped. That is exactly why this menu only ever showed up on
/// iPad, where the same modifier happened to sit inside the `NavigationSplitView`.
struct DebugMenuButton: View {
    @Binding var isPresented: Bool

    var body: some View {
        Button {
            isPresented = true
        } label: {
            Image(systemName: "ladybug.fill")
        }
        .accessibilityLabel(Text(verbatim: "Debug menu"))
    }
}

extension View {
    func debugMenu(isPresented: Binding<Bool>) -> some View {
        sheet(isPresented: isPresented) { DebugMenuSheet() }
    }
}

private struct DebugMenuSheet: View {
    @Environment(\.dismiss) private var dismiss
    /// What the last action reported, shown inline — a debug action that changes only `UserDefaults` gives no other
    /// sign that it ran.
    @State private var lastResult: String?
    /// Mirrors `ReaderHints.ignoresPerLaunchBudget`, which is `UserDefaults`-backed rather than observable.
    @State private var ignoresPerLaunchBudget = ReaderHints.ignoresPerLaunchBudget

    var body: some View {
        NavigationStack {
            Form {
                coachMarkSection
                crashSection
                resultSection
            }
            .onChange(of: ignoresPerLaunchBudget) { _, new in
                ReaderHints.ignoresPerLaunchBudget = new
            }
            .navigationTitle(Text(verbatim: "Debug"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: { Text(verbatim: "Done") }
                }
            }
        }
    }

    private var coachMarkSection: some View {
        Section {
            Button {
                ReaderHints.resetAll()
                lastResult = "Coach marks reset — open a score to see the next one."
            } label: {
                Text(verbatim: "Reset reader coach marks")
            }
            Toggle(isOn: $ignoresPerLaunchBudget) {
                Text(verbatim: "Offer one every time")
            }
        } header: {
            Text(verbatim: "Coach marks")
        } footer: {
            Text(verbatim: """
            Reset forgets every "already used" flag and rewinds the rotation, so the next hint offered is the \
            transport's again. With the toggle on, the one-per-launch budget stops applying — leave a score and \
            come back in to walk the rotation one hint at a time instead of relaunching per hint.
            """)
        }
    }

    private var crashSection: some View {
        Section {
            Button(role: .destructive) {
                fatalError("Crashed manually.")
            } label: {
                Text(verbatim: "fatalError")
            }
        } header: {
            Text(verbatim: "Crash")
        }
    }

    @ViewBuilder
    private var resultSection: some View {
        if let lastResult {
            Section {
                Text(verbatim: lastResult)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
#endif
