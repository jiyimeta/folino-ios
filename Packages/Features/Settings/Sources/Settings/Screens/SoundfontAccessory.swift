import Domain
import SwiftUI

/// Trailing control for the high-quality soundfont row. The accessory morphs based on the download state:
///
/// - downloading → determinate circular progress + stop button (cancels the in-flight download)
/// - opted-in + idle → indeterminate spinner + stop button (opts out)
/// - everything else → standard `Toggle`
///
/// Inputs are narrowed to the two state values it reads plus the three callbacks it invokes, so it invalidates
/// only when the download state / opt-in flag changes.
struct SoundfontAccessory: View {
    let downloadState: SoundfontDownloadState
    let isOptedIn: Bool
    let toggleBinding: Binding<Bool>
    let onCancelDownload: () -> Void
    let onStopOptOut: () -> Void

    var body: some View {
        if case let .downloading(progress) = downloadState {
            stopSpinner(determinate: progress) {
                onCancelDownload()
            }
        } else if isOptedIn, case .idle = downloadState {
            // Opted in but waiting for the network policy / next Wi-Fi window. Show an indeterminate spinner with the
            // same visual weight as the downloading state; tapping the stop button opts out (matches the user's
            // expectation that the spinner means "in progress" and the stop button means "stop trying").
            stopSpinner(determinate: nil) {
                onStopOptOut()
            }
        } else {
            Toggle("", isOn: toggleBinding)
                .labelsHidden()
        }
    }

    private func stopSpinner(
        determinate progress: Double?,
        onTap: @escaping () -> Void,
    ) -> some View {
        Button(action: onTap) {
            ZStack {
                Circle()
                    .stroke(.secondary.opacity(0.25), lineWidth: 3)
                if let progress {
                    Circle()
                        .trim(from: 0, to: max(0.02, progress))
                        .stroke(
                            .tint,
                            style: StrokeStyle(lineWidth: 3, lineCap: .round),
                        )
                        .rotationEffect(.degrees(-90))
                } else {
                    IndeterminateArc()
                }
                Image(systemName: "stop.fill")
                    .imageScale(.small)
                    .foregroundStyle(.tint)
            }
            .frame(width: 28, height: 28)
            .contentShape(Circle())
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(Text("settings.soundfont.stop.label", bundle: .module))
    }
}

/// Continuously-spinning arc, matching the visual weight of the determinate progress arc. Lives in its own struct so
/// `@State` can drive the `withAnimation` repeat without leaking the animation flag into the parent view's state.
private struct IndeterminateArc: View {
    @State private var angle: Double = 0

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.25)
            .stroke(
                .tint,
                style: StrokeStyle(lineWidth: 3, lineCap: .round),
            )
            .rotationEffect(.degrees(angle))
            .onAppear {
                withAnimation(.linear(duration: 1.0).repeatForever(autoreverses: false)) {
                    angle = 360
                }
            }
    }
}
