import Domain
import Foundation
import Library
import Reader
import SwiftUI
import UtilityCore

/// One Mac score window: the reader fills it, and nothing else is in it. The library is its own single-instance
/// `Window` scene now (`MacWindowID.library`), so this view has no sidebar, no split view and no library rows — see
/// the design spec §2.1 for why the two could not share a window.
///
/// Every score window comes from the same `WindowGroup(for: MacWindowScore.self)`, and `MacWindowTabAssist` in the
/// background gives them all one AppKit tabbing identity so macOS can group them as tabs.
struct MacShellView: View {
    let bootstrap: AppBootstrap
    /// The window's own identity value, as `WindowGroup(for: MacWindowScore.self)` presents it. Taken by value, not
    /// as a `Binding`: a window's score is fixed the moment `openWindow(value:)` mints it, because opening a score
    /// is now opening a *window* rather than swapping a detail column's content, so nothing here ever writes it back.
    let window: MacWindowScore?
    /// The process's one `LibraryViewModel`, owned by `FolinoMacApp`. This window needs it for exactly one thing:
    /// publishing File ▸ Import as a focused scene value, so the menu command still works while a score window is
    /// key. `@FocusedValue` follows *scene* focus, so the browser window's own publication is invisible from here —
    /// a score window has to publish its own, and it has to be the same view model the browser is watching.
    let libraryVM: LibraryViewModel
    @Environment(\.openWindow) private var openWindow

    /// The adapters this window's reader needs, unwrapped once in `init` (see the guard there for why they are
    /// guaranteed non-nil) rather than at every use site.
    private let repository: any ScoreLibraryRepository
    private let originalStore: any ScoreOriginalStore
    private let gateway: any ScoreFileGateway
    private let shareService: any ScoreShareService
    private let metadataReader: any ScoreMetadataReading
    private let annotationCoordinator: AnnotationSaveCoordinator

    /// The score this window is showing, read out of the window's identity value. That value also carries a
    /// `tabInstance` nothing here reads — see `MacWindowScore`'s doc comment for the deduplication it exists for.
    private var scoreID: ScoreItem.ID? {
        window?.scoreID
    }

    init(bootstrap: AppBootstrap, window: MacWindowScore?, libraryVM: LibraryViewModel) {
        self.bootstrap = bootstrap
        self.window = window
        self.libraryVM = libraryVM
        // Every adapter read below is guaranteed non-nil here: `FolinoMacApp` only builds `MacShellView` once
        // `bootstrap.isReady` is true, and `AppBootstrap.start()` populates all of them synchronously before it
        // flips that flag (see the `Task { [weak self] in await self?.finishStartup(...) }` at the end of `start()`
        // — everything above that line already ran).
        guard let repository = bootstrap.repository,
              let gateway = bootstrap.gateway,
              let originalStore = bootstrap.originalStore,
              let shareService = bootstrap.shareService,
              let metadataReader = bootstrap.metadataReader,
              let annotationCoordinator = bootstrap.annotationCoordinator
        else {
            fatalError("MacShellView built before AppBootstrap finished starting")
        }
        self.repository = repository
        self.originalStore = originalStore
        self.gateway = gateway
        self.shareService = shareService
        self.metadataReader = metadataReader
        self.annotationCoordinator = annotationCoordinator
    }

    var body: some View {
        content
            .frame(minWidth: 900, minHeight: 600)
            .background(MacWindowTabAssist())
            .focusedSceneValue(\.macLibraryImportAction) { url in await libraryVM.startImport(from: url) }
            // A score window must open what its own File ▸ Import brought in, even with the browser closed — see
            // `ImportedScoreOpener`. The browser installs the same watcher; `MacImportedScoreClaim` is what stops
            // them from opening the score twice.
            .opensImportedScores(from: libraryVM)
            .focusedCurrentScoreID(scoreID)
    }

    @ViewBuilder
    private var content: some View {
        if let item = openScoreItem {
            // `id(item.id)` so switching the window to another score builds a fresh `MacReaderRootScreen` — and with
            // it a fresh `ReaderViewModel`, which is created once per screen instance in a `@State`.
            MacReaderRootScreen(
                scoreItem: item,
                repository: repository,
                originalStore: originalStore,
                gateway: gateway,
                shareService: shareService,
                metadataReader: metadataReader,
                annotationCoordinator: annotationCoordinator,
                scoresDirectory: AppPaths.scoresDirectory,
                playbackController: bootstrap.playbackController,
                // The same OMR parser the iOS shell passes. It is what gives an imported PDF its on-PDF cursor and
                // click-to-seek; without it the document still reads, it just carries no musical positions.
                pdfPlaybackParser: bootstrap.pdfPlaybackParser,
                analytics: bootstrap.analytics ?? NoopAnalytics(),
            )
            .id(item.id)
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    Button {
                        openWindow(id: MacWindowID.library)
                    } label: {
                        Label {
                            Text("mac.toolbar.showLibrary")
                        } icon: {
                            Image(systemName: "square.grid.2x2")
                        }
                    }
                }
            }
        } else {
            // No score chosen yet — or the window's `scoreID` names a row the library no longer holds (deleted from
            // the browser, or a restored window value that outlived its score). Both read as an empty window.
            ContentUnavailableView {
                Label {
                    Text("app.detail.empty.title")
                } icon: {
                    Image(systemName: "music.note")
                }
            }
        }
    }

    /// The `ScoreItem` this window's `scoreID` names, looked up in the library's live rows (`scoreItems` excludes
    /// soft-deleted ones — those are `deletedScoreItems`). Two things only: the reader is built from the current row
    /// rather than a stale copy, and a `scoreID` whose row is gone yields `nil` and an empty window. It does NOT
    /// push later edits into a reader that is already open — `MacReaderRootScreen` seeds its view model once per
    /// `.id(item.id)`, and a title edit does not change the id.
    private var openScoreItem: ScoreItem? {
        guard let scoreID else { return nil }
        return repository.scoreItems.first { $0.id == scoreID }
    }
}

extension View {
    /// Publishes `id` as this window's focused score, for `MacCommands`'s File ▸ Open in New Window to read via
    /// `@FocusedValue`. Omitted entirely (rather than published as `nil`) when there is no open score, which is
    /// exactly what leaves `@FocusedValue` reading `nil` and the menu command disabled.
    @ViewBuilder
    fileprivate func focusedCurrentScoreID(_ id: ScoreItem.ID?) -> some View {
        if let id {
            focusedSceneValue(\.macCurrentScoreID, id)
        } else {
            self
        }
    }
}
