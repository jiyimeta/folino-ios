import Domain
import Foundation
@testable import Reader

/// Builds a `ReaderViewModel` wired to the screenshot fixtures, for the inspector scenes (Playback / Visual / A-B
/// Repeat) which render the inspector panels against its sub-models. `ReaderViewModel` is `internal` to the Reader
/// package, so this lives behind `@testable import Reader` — same access path the inspector scenes use.
///
/// The sub-models (`mixerModel`, `tempoModel`, `layoutModel`, …) are seeded by `await viewModel.load()`. Inspector
/// scenes call `load()` in a `.task`; the live capture run waits long enough for it to complete, and the panels render
/// populated from `Fixture.score` plus sensible model defaults even before it does.
enum InspectorFixtureViewModel {
    @MainActor
    static func make() -> ReaderViewModel {
        // Read the live device defaults rather than pinning numbers: the marketing captures run on both an iPhone
        // and an iPad simulator (`Scripts/capture-screenshots.sh`), and the Visual inspector scene renders the
        // resolved staff size as visible text, so each capture has to see its own device-class pair.
        ReaderViewModel(
            scoreItem: Fixture.items[0],
            repository: FixtureScoreRepository(),
            gateway: FixtureGateway(),
            shareService: FixtureShareService(),
            metadataReader: FixtureMetadataReader(),
            scoresDirectory: URL(filePath: NSTemporaryDirectory()),
            defaultStaffSize: ReaderDeviceDefaults.staffSize,
            defaultHonorLayoutBreaks: ReaderDeviceDefaults.honorLayoutBreaks,
        )
    }
}
