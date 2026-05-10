// swiftlint:disable file_length type_body_length
import Domain
import Foundation
@testable import Reader
import SheetMusicCore
import Testing

@Suite @MainActor
struct ReaderViewModelPlaybackTests {
    private static func makeItem() -> ScoreItem {
        ScoreItem(
            title: "Test", composer: nil, instrumentationSummary: nil,
            localFileName: "test.mscx", contentHash: "hash",
            sizeBytes: 0, lengthBeats: 0, defaultTempoBpm: 120, primaryKey: nil,
            addedAt: Date(timeIntervalSince1970: 1_700_000_000),
            lastOpenedAt: nil, tagIDs: [], isFavorite: false
        )
    }

    private static func makeGateway(score: Score) -> FakeScoreFileGateway {
        FakeScoreFileGateway(loadScoreResult: .success((
            score: score,
            summary: ScoreFileSummary(
                title: "Test", composer: nil, instrumentationSummary: "",
                lengthBeats: 0, defaultTempoBpm: 120, primaryKey: nil
            )
        )))
    }

    @Test func playbackCursorMirrorsControllerStream() {
        let item = Self.makeItem()
        let repo = FakeScoreLibraryRepository()
        repo.scoreItems = [item]
        let controller = FakePlaybackController()
        let vm = ReaderViewModel(
            scoreItem: item, repository: repo,
            gateway: FakeScoreFileGateway(),
            scoresDirectory: URL(filePath: "/tmp"),
            playbackController: controller
        )
        vm.startObservingCursor()
        let target = ScoreCursor.beat(measureIndex: 4, tickInMeasure: 240)
        controller.emitCursor(target)
        #expect(vm.playbackCursor == target)

        controller.emitCursor(nil)
        #expect(vm.playbackCursor == nil)
    }

    @Test func cursorBecomingNilAfterPlayResetsIsPlaying() async {
        // The engine emits a nil cursor when playback finishes naturally
        // (`PlaybackEngine.stop()` clears `currentCursor` once
        // `tickCursor` reaches `totalTicks`). The toolbar's play/pause
        // glyph is bound to `isPlaying`, so it must flip back to "play"
        // when that signal arrives.
        let item = Self.makeItem()
        let repo = FakeScoreLibraryRepository()
        repo.scoreItems = [item]
        let score = Score(
            division: 480,
            parts: [Part(id: "P0", trackName: "Vn", instrument: Instrument(id: "v"), staves: [Staff()])],
            metaTags: [:]
        )
        let controller = FakePlaybackController()
        let vm = ReaderViewModel(
            scoreItem: item, repository: repo, gateway: Self.makeGateway(score: score),
            scoresDirectory: URL(filePath: "/tmp"),
            playbackController: controller
        )
        await vm.load()
        vm.startObservingCursor()
        await vm.togglePlayback()
        #expect(vm.isPlaying)

        controller.emitCursor(nil)
        #expect(!vm.isPlaying)
    }

    @Test func togglePlaybackLoadsPlaysThenPauses() async {
        let item = Self.makeItem()
        let repo = FakeScoreLibraryRepository()
        repo.scoreItems = [item]
        let score = Score(
            division: 480,
            parts: [Part(id: "P0", trackName: "Vn", instrument: Instrument(id: "v"), staves: [Staff()])],
            metaTags: [:]
        )
        let controller = FakePlaybackController()
        let vm = ReaderViewModel(
            scoreItem: item, repository: repo, gateway: Self.makeGateway(score: score),
            scoresDirectory: URL(filePath: "/tmp"),
            playbackController: controller
        )
        await vm.load()

        await vm.togglePlayback()
        #expect(controller.loadCount == 1)
        #expect(controller.playCount == 1)
        #expect(vm.isPlaying)

        await vm.togglePlayback()
        #expect(controller.pauseCount == 1)
        #expect(controller.loadCount == 1) // load only happens once
        #expect(!vm.isPlaying)
    }

    @Test func cancelLoadingSoundfontsAbortsTogglePlayback() async {
        let item = Self.makeItem()
        let repo = FakeScoreLibraryRepository()
        repo.scoreItems = [item]
        let score = Score(
            division: 480,
            parts: [Part(id: "P0", trackName: "Vn", instrument: Instrument(id: "v"), staves: [Staff()])],
            metaTags: [:]
        )
        let controller = FakePlaybackController()
        controller.blocksLoadUntilCancelled = true
        let vm = ReaderViewModel(
            scoreItem: item, repository: repo, gateway: Self.makeGateway(score: score),
            scoresDirectory: URL(filePath: "/tmp"),
            playbackController: controller
        )
        await vm.load()

        let toggle = Task { await vm.togglePlayback() }
        for _ in 0 ..< 5 { await Task.yield() }
        #expect(vm.isLoadingSoundfonts)
        #expect(!vm.isPlaying)
        #expect(controller.loadCount == 0)

        vm.cancelLoadingSoundfonts()
        _ = await toggle.value
        #expect(!vm.isLoadingSoundfonts)
        #expect(!vm.isPlaying)
        #expect(controller.playCount == 0)
    }

    @Test func prepareForPlaybackPrimesEngineWithoutShowingAlert() async {
        let item = Self.makeItem()
        let repo = FakeScoreLibraryRepository()
        repo.scoreItems = [item]
        let score = Score(
            division: 480,
            parts: [Part(id: "P0", trackName: "Vn", instrument: Instrument(id: "v"), staves: [Staff()])],
            metaTags: [:]
        )
        let controller = FakePlaybackController()
        let vm = ReaderViewModel(
            scoreItem: item, repository: repo, gateway: Self.makeGateway(score: score),
            scoresDirectory: URL(filePath: "/tmp"),
            playbackController: controller
        )
        await vm.load()
        await vm.prepareForPlayback()

        #expect(controller.loadCount == 1)
        #expect(vm.soundfontAlertKind == nil)

        // First user-driven toggle should reuse the primed engine — no
        // additional load and no alert flash.
        await vm.togglePlayback()
        #expect(controller.loadCount == 1)
        #expect(controller.playCount == 1)
        #expect(vm.soundfontAlertKind == nil)
        #expect(vm.isPlaying)
    }

    @Test func togglePlaybackShowsOfflineAlertWhenOfflineAndUncached() async {
        let item = Self.makeItem()
        let repo = FakeScoreLibraryRepository()
        repo.scoreItems = [item]
        let score = Score(
            division: 480,
            parts: [Part(id: "P0", trackName: "Vn", instrument: Instrument(id: "v"), staves: [Staff()])],
            metaTags: [:]
        )
        let controller = FakePlaybackController()
        controller.soundfontsAvailableLocally = false
        controller.blocksLoadUntilCancelled = true
        let reachability = FakeNetworkReachability(online: false)
        let vm = ReaderViewModel(
            scoreItem: item, repository: repo, gateway: Self.makeGateway(score: score),
            scoresDirectory: URL(filePath: "/tmp"),
            playbackController: controller,
            reachability: reachability
        )
        await vm.load()

        let toggle = Task { await vm.togglePlayback() }
        for _ in 0 ..< 5 { await Task.yield() }
        #expect(vm.soundfontAlertKind == .offline)
        #expect(!vm.isLoadingSoundfonts)

        vm.cancelLoadingSoundfonts()
        _ = await toggle.value
        #expect(vm.soundfontAlertKind == nil)
    }

    @Test func togglePlaybackShowsLoadingAlertWhenOnlineAndUncached() async {
        let item = Self.makeItem()
        let repo = FakeScoreLibraryRepository()
        repo.scoreItems = [item]
        let score = Score(
            division: 480,
            parts: [Part(id: "P0", trackName: "Vn", instrument: Instrument(id: "v"), staves: [Staff()])],
            metaTags: [:]
        )
        let controller = FakePlaybackController()
        controller.soundfontsAvailableLocally = false
        controller.blocksLoadUntilCancelled = true
        let reachability = FakeNetworkReachability(online: true)
        let vm = ReaderViewModel(
            scoreItem: item, repository: repo, gateway: Self.makeGateway(score: score),
            scoresDirectory: URL(filePath: "/tmp"),
            playbackController: controller,
            reachability: reachability
        )
        await vm.load()

        let toggle = Task { await vm.togglePlayback() }
        for _ in 0 ..< 5 { await Task.yield() }
        #expect(vm.soundfontAlertKind == .loading)

        vm.cancelLoadingSoundfonts()
        _ = await toggle.value
        #expect(vm.soundfontAlertKind == nil)
    }

    @Test func togglePlaybackSkipsAlertWhenSoundfontsAreCached() async {
        let item = Self.makeItem()
        let repo = FakeScoreLibraryRepository()
        repo.scoreItems = [item]
        let score = Score(
            division: 480,
            parts: [Part(id: "P0", trackName: "Vn", instrument: Instrument(id: "v"), staves: [Staff()])],
            metaTags: [:]
        )
        let controller = FakePlaybackController()
        controller.soundfontsAvailableLocally = true
        controller.blocksLoadUntilCancelled = true
        let vm = ReaderViewModel(
            scoreItem: item, repository: repo, gateway: Self.makeGateway(score: score),
            scoresDirectory: URL(filePath: "/tmp"),
            playbackController: controller
        )
        await vm.load()

        let toggle = Task { await vm.togglePlayback() }
        for _ in 0 ..< 5 { await Task.yield() }
        // Even though `load` is blocked, the alert never shows because the
        // controller reports the cache covers the score.
        #expect(!vm.isLoadingSoundfonts)

        vm.cancelLoadingSoundfonts()
        _ = await toggle.value
        #expect(!vm.isLoadingSoundfonts)
        #expect(!vm.isPlaying)
    }

    @Test func togglePlaybackIsNoOpWhenScoreNotLoaded() async {
        let item = Self.makeItem()
        let repo = FakeScoreLibraryRepository()
        repo.scoreItems = [item]
        let controller = FakePlaybackController()
        let vm = ReaderViewModel(
            scoreItem: item, repository: repo,
            gateway: FakeScoreFileGateway(),
            scoresDirectory: URL(filePath: "/tmp"),
            playbackController: controller
        )
        // No `await vm.load()`.
        await vm.togglePlayback()
        #expect(controller.loadCount == 0)
        #expect(controller.playCount == 0)
        #expect(!vm.isPlaying)
    }

    @Test func toggleStaffSoloFlipsMembershipAndForwardsToController() async {
        let item = Self.makeItem()
        let repo = FakeScoreLibraryRepository()
        repo.scoreItems = [item]
        let score = Score(
            division: 480,
            parts: [
                Part(id: "P0", trackName: "Vn", instrument: Instrument(id: "v"), staves: [Staff()]),
                Part(id: "P1", trackName: "Pno", instrument: Instrument(id: "p"), staves: [Staff(), Staff()]),
            ],
            metaTags: [:]
        )
        let controller = FakePlaybackController()
        let vm = ReaderViewModel(
            scoreItem: item, repository: repo, gateway: Self.makeGateway(score: score),
            scoresDirectory: URL(filePath: "/tmp"),
            playbackController: controller
        )
        await vm.load()

        // Piano top staff → flat index 1 (Vn=0, Pno-top=1, Pno-bottom=2).
        let pianoTop = StaffAddress(partIndex: 1, staffIndexInPart: 0)
        vm.toggleStaffSolo(address: pianoTop)
        #expect(vm.soloStaves == [pianoTop])
        for _ in 0 ..< 5 { await Task.yield() }
        #expect(controller.staffSoloStates[1] == true)

        vm.toggleStaffSolo(address: pianoTop)
        #expect(vm.soloStaves.isEmpty)
        for _ in 0 ..< 5 { await Task.yield() }
        #expect(controller.staffSoloStates[1] == false)
    }

    @Test func toggleStaffSoloIsNoOpWhenScoreNotLoaded() async {
        let item = Self.makeItem()
        let repo = FakeScoreLibraryRepository()
        repo.scoreItems = [item]
        let controller = FakePlaybackController()
        let vm = ReaderViewModel(
            scoreItem: item, repository: repo,
            gateway: FakeScoreFileGateway(),
            scoresDirectory: URL(filePath: "/tmp"),
            playbackController: controller
        )
        // No load: flat index lookup fails, controller is never called,
        // but the in-memory set still tracks the user's intent.
        let address = StaffAddress(partIndex: 0, staffIndexInPart: 0)
        vm.toggleStaffSolo(address: address)
        #expect(vm.soloStaves == [address])
        for _ in 0 ..< 5 { await Task.yield() }
        #expect(controller.staffSoloStates.isEmpty)
    }

    @Test func effectiveProgramFallsBackToScoreInstrumentChannel() async {
        let item = Self.makeItem()
        let repo = FakeScoreLibraryRepository()
        repo.scoreItems = [item]
        let violinChannel = InstrumentChannel(program: 40) // GM 40 = Violin
        let pianoChannel = InstrumentChannel(program: 0) // GM 0 = Piano
        let score = Score(
            division: 480,
            parts: [
                Part(
                    id: "P0", trackName: "Vn",
                    instrument: Instrument(id: "v", channels: [violinChannel]),
                    staves: [Staff()]
                ),
                Part(
                    id: "P1", trackName: "Pno",
                    instrument: Instrument(id: "p", channels: [pianoChannel]),
                    staves: [Staff(), Staff()]
                ),
            ],
            metaTags: [:]
        )
        let vm = ReaderViewModel(
            scoreItem: item, repository: repo, gateway: Self.makeGateway(score: score),
            scoresDirectory: URL(filePath: "/tmp")
        )
        await vm.load()

        let violinAddress = StaffAddress(partIndex: 0, staffIndexInPart: 0)
        let pianoTopAddress = StaffAddress(partIndex: 1, staffIndexInPart: 0)
        #expect(vm.effectiveProgram(for: violinAddress) == 40)
        #expect(vm.effectiveProgram(for: pianoTopAddress) == 0)
        #expect(!vm.hasProgramOverride(for: violinAddress))
    }

    @Test func setStaffProgramPersistsOverrideAndForwardsToController() async {
        let item = Self.makeItem()
        let repo = FakeScoreLibraryRepository()
        repo.scoreItems = [item]
        let score = Score(
            division: 480,
            parts: [
                Part(
                    id: "P0", trackName: "Vn",
                    instrument: Instrument(id: "v", channels: [InstrumentChannel(program: 40)]),
                    staves: [Staff()]
                ),
            ],
            metaTags: [:]
        )
        let controller = FakePlaybackController()
        let vm = ReaderViewModel(
            scoreItem: item, repository: repo, gateway: Self.makeGateway(score: score),
            scoresDirectory: URL(filePath: "/tmp"),
            playbackController: controller
        )
        await vm.load()

        let address = StaffAddress(partIndex: 0, staffIndexInPart: 0)
        await vm.setStaffProgram(6, for: address) // Harpsichord
        #expect(vm.effectiveProgram(for: address) == 6)
        #expect(vm.hasProgramOverride(for: address))
        #expect(vm.preferences.staffProgramOverrides[address] == 6)
        // Saved to repository.
        let saved = try? #require(repo.savedReaderPreferences.last)
        #expect(saved?.staffProgramOverrides[address] == 6)
        // Forwarded to the controller with bank 0.
        let call = try? #require(controller.staffInstrumentCalls.last)
        #expect(call?.staff == 0)
        #expect(call?.bank == 0)
        #expect(call?.program == 6)
    }

    @Test func clearStaffProgramOverrideRevertsToScoreDefault() async {
        let item = Self.makeItem()
        let repo = FakeScoreLibraryRepository()
        repo.scoreItems = [item]
        let score = Score(
            division: 480,
            parts: [
                Part(
                    id: "P0", trackName: "Vn",
                    instrument: Instrument(id: "v", channels: [InstrumentChannel(program: 40)]),
                    staves: [Staff()]
                ),
            ],
            metaTags: [:]
        )
        let controller = FakePlaybackController()
        let vm = ReaderViewModel(
            scoreItem: item, repository: repo, gateway: Self.makeGateway(score: score),
            scoresDirectory: URL(filePath: "/tmp"),
            playbackController: controller
        )
        await vm.load()

        let address = StaffAddress(partIndex: 0, staffIndexInPart: 0)
        await vm.setStaffProgram(6, for: address)
        await vm.clearStaffProgramOverride(for: address)

        #expect(!vm.hasProgramOverride(for: address))
        #expect(vm.effectiveProgram(for: address) == 40)
        #expect(vm.preferences.staffProgramOverrides[address] == nil)
        let lastCall = try? #require(controller.staffInstrumentCalls.last)
        #expect(lastCall?.program == 40) // reset call uses score default
    }

    @Test func initialPlaybackPreferencesUseOverridesAndScoreDefaults() async throws {
        let item = Self.makeItem()
        let repo = FakeScoreLibraryRepository()
        repo.scoreItems = [item]
        let address2 = StaffAddress(partIndex: 1, staffIndexInPart: 0)
        repo.storedReaderPreferences[item.id] = ReaderPreferences(
            scoreItemID: item.id, staffSize: 14, hiddenStaves: [],
            staffProgramOverrides: [address2: 24] // Acoustic Guitar
        )
        let score = Score(
            division: 480,
            parts: [
                Part(
                    id: "P0", trackName: "Vn",
                    instrument: Instrument(id: "v", channels: [InstrumentChannel(program: 40)]),
                    staves: [Staff()]
                ),
                Part(
                    id: "P1", trackName: "Pno",
                    instrument: Instrument(id: "p", channels: [InstrumentChannel(program: 0)]),
                    staves: [Staff()]
                ),
            ],
            metaTags: [:]
        )
        let controller = FakePlaybackController()
        let vm = ReaderViewModel(
            scoreItem: item, repository: repo, gateway: Self.makeGateway(score: score),
            scoresDirectory: URL(filePath: "/tmp"),
            playbackController: controller
        )
        await vm.load()
        await vm.togglePlayback()

        let prefs = try #require(controller.lastLoadedPreferences)
        #expect(prefs.perStaff[0].gmProgram == 40) // violin uses score default
        #expect(prefs.perStaff[1].gmProgram == 24) // piano uses override
    }

    @Test func setVolumeForwardsToControllerByFlatStaffIndex() async {
        let item = Self.makeItem()
        let repo = FakeScoreLibraryRepository()
        repo.scoreItems = [item]
        let score = Score(
            division: 480,
            parts: [
                Part(id: "P0", trackName: "Vn", instrument: Instrument(id: "v"), staves: [Staff()]),
                Part(id: "P1", trackName: "Pno", instrument: Instrument(id: "p"), staves: [Staff(), Staff()]),
            ],
            metaTags: [:]
        )
        let controller = FakePlaybackController()
        let vm = ReaderViewModel(
            scoreItem: item, repository: repo, gateway: Self.makeGateway(score: score),
            scoresDirectory: URL(filePath: "/tmp"),
            playbackController: controller
        )
        await vm.load()

        // Piano's lower staff is at (partIndex: 1, staffIndexInPart: 1)
        // → flat staff index 2 (Vn=0, Pno-top=1, Pno-bottom=2).
        let pianoBottom = StaffAddress(partIndex: 1, staffIndexInPart: 1)
        vm.setVolume(0.3, for: pianoBottom)
        await Task.yield()
        await Task.yield()
        #expect(controller.staffVolumes[2] == 0.3)
    }

    @Test func setPartProgramWithCachedPatchSkipsPrefetch() async {
        let item = Self.makeItem()
        let repo = FakeScoreLibraryRepository()
        repo.scoreItems = [item]
        let score = Score(
            division: 480,
            parts: [
                Part(
                    id: "P0", trackName: "Vn",
                    instrument: Instrument(id: "v", channels: [InstrumentChannel(program: 40)]),
                    staves: [Staff()]
                ),
            ],
            metaTags: [:]
        )
        let controller = FakePlaybackController()
        controller.cachedPatches = [SoundfontPatchKey(bank: 0, program: 6, isDrums: false)]
        let vm = ReaderViewModel(
            scoreItem: item, repository: repo, gateway: Self.makeGateway(score: score),
            scoresDirectory: URL(filePath: "/tmp"),
            playbackController: controller
        )
        await vm.load()

        await vm.setPartProgram(6, forPartIndex: 0)

        #expect(controller.prefetchedPatches.isEmpty)
        #expect(vm.soundfontAlertKind == nil)
        let calls = controller.staffInstrumentCalls.filter { $0.program == 6 }
        #expect(calls.count == 1)
    }

    @Test func setPartProgramWithUncachedPatchPrefetchesSilentlyWhenNotPlaying() async {
        let item = Self.makeItem()
        let repo = FakeScoreLibraryRepository()
        repo.scoreItems = [item]
        let score = Score(
            division: 480,
            parts: [
                Part(
                    id: "P0", trackName: "Vn",
                    instrument: Instrument(id: "v", channels: [InstrumentChannel(program: 40)]),
                    staves: [Staff()]
                ),
            ],
            metaTags: [:]
        )
        let controller = FakePlaybackController()
        // cachedPatches deliberately empty — every pick is a miss.
        let vm = ReaderViewModel(
            scoreItem: item, repository: repo, gateway: Self.makeGateway(score: score),
            scoresDirectory: URL(filePath: "/tmp"),
            playbackController: controller
        )
        await vm.load()

        await vm.setPartProgram(6, forPartIndex: 0)

        #expect(vm.soundfontAlertKind == nil)
        #expect(controller.prefetchedPatches.contains(
            SoundfontPatchKey(bank: 0, program: 6, isDrums: false)
        ))
        // Engine reflection happens after prefetch resolves.
        let calls = controller.staffInstrumentCalls.filter { $0.program == 6 }
        #expect(calls.count == 1)
        #expect(vm.preferences.staffProgramOverrides[
            StaffAddress(partIndex: 0, staffIndexInPart: 0)
        ] == 6)
    }

    @Test func setPartProgramDuringPlaybackPausesAndShowsLoadingAlert() async {
        let item = Self.makeItem()
        let repo = FakeScoreLibraryRepository()
        repo.scoreItems = [item]
        let score = Score(
            division: 480,
            parts: [
                Part(
                    id: "P0", trackName: "Vn",
                    instrument: Instrument(id: "v", channels: [InstrumentChannel(program: 40)]),
                    staves: [Staff()]
                ),
            ],
            metaTags: [:]
        )
        let controller = FakePlaybackController()
        controller.cachedPatches = [SoundfontPatchKey(bank: 0, program: 40, isDrums: false)]
        controller.blocksPrefetchUntilCancelled = true
        let reachability = FakeNetworkReachability(online: true)
        let vm = ReaderViewModel(
            scoreItem: item, repository: repo, gateway: Self.makeGateway(score: score),
            scoresDirectory: URL(filePath: "/tmp"),
            playbackController: controller,
            reachability: reachability
        )
        await vm.load()
        controller.soundfontsAvailableLocally = true
        await vm.togglePlayback()
        #expect(vm.isPlaying)

        let pick = Task { await vm.setPartProgram(6, forPartIndex: 0) }
        for _ in 0 ..< 5 { await Task.yield() }
        #expect(!vm.isPlaying)
        #expect(vm.soundfontAlertKind == .loading)
        #expect(controller.pauseCount == 1)

        vm.cancelLoadingSoundfonts()
        _ = await pick.value
        #expect(vm.soundfontAlertKind == nil)
    }

    @Test func setPartProgramDuringPlaybackResumesAfterPrefetchSucceeds() async {
        let item = Self.makeItem()
        let repo = FakeScoreLibraryRepository()
        repo.scoreItems = [item]
        let score = Score(
            division: 480,
            parts: [
                Part(
                    id: "P0", trackName: "Vn",
                    instrument: Instrument(id: "v", channels: [InstrumentChannel(program: 40)]),
                    staves: [Staff()]
                ),
            ],
            metaTags: [:]
        )
        let controller = FakePlaybackController()
        controller.cachedPatches = [SoundfontPatchKey(bank: 0, program: 40, isDrums: false)]
        let reachability = FakeNetworkReachability(online: true)
        let vm = ReaderViewModel(
            scoreItem: item, repository: repo, gateway: Self.makeGateway(score: score),
            scoresDirectory: URL(filePath: "/tmp"),
            playbackController: controller,
            reachability: reachability
        )
        await vm.load()
        controller.soundfontsAvailableLocally = true
        await vm.togglePlayback()
        let playsBefore = controller.playCount
        #expect(vm.isPlaying)

        await vm.setPartProgram(6, forPartIndex: 0)

        #expect(vm.isPlaying)
        #expect(controller.playCount == playsBefore + 1)
        #expect(controller.pauseCount == 1)
        let calls = controller.staffInstrumentCalls.filter { $0.program == 6 }
        #expect(calls.count == 1)
    }

    @Test func setPartProgramDuringPlaybackShowsOfflineAlertWhenOffline() async {
        let item = Self.makeItem()
        let repo = FakeScoreLibraryRepository()
        repo.scoreItems = [item]
        let score = Score(
            division: 480,
            parts: [
                Part(
                    id: "P0", trackName: "Vn",
                    instrument: Instrument(id: "v", channels: [InstrumentChannel(program: 40)]),
                    staves: [Staff()]
                ),
            ],
            metaTags: [:]
        )
        let controller = FakePlaybackController()
        controller.cachedPatches = [SoundfontPatchKey(bank: 0, program: 40, isDrums: false)]
        controller.blocksPrefetchUntilCancelled = true
        let reachability = FakeNetworkReachability(online: false)
        let vm = ReaderViewModel(
            scoreItem: item, repository: repo, gateway: Self.makeGateway(score: score),
            scoresDirectory: URL(filePath: "/tmp"),
            playbackController: controller,
            reachability: reachability
        )
        await vm.load()
        controller.soundfontsAvailableLocally = true
        await vm.togglePlayback()

        let pick = Task { await vm.setPartProgram(6, forPartIndex: 0) }
        for _ in 0 ..< 5 { await Task.yield() }
        #expect(vm.soundfontAlertKind == .offline)

        vm.cancelLoadingSoundfonts()
        _ = await pick.value
    }

    @Test func cancelDuringInstrumentPrefetchRevertsProgramOverride() async {
        let item = Self.makeItem()
        let repo = FakeScoreLibraryRepository()
        repo.scoreItems = [item]
        let score = Score(
            division: 480,
            parts: [
                Part(
                    id: "P0", trackName: "Vn",
                    instrument: Instrument(id: "v", channels: [InstrumentChannel(program: 40)]),
                    staves: [Staff()]
                ),
            ],
            metaTags: [:]
        )
        let controller = FakePlaybackController()
        controller.blocksPrefetchUntilCancelled = true
        let vm = ReaderViewModel(
            scoreItem: item, repository: repo, gateway: Self.makeGateway(score: score),
            scoresDirectory: URL(filePath: "/tmp"),
            playbackController: controller
        )
        await vm.load()

        let address = StaffAddress(partIndex: 0, staffIndexInPart: 0)
        let pick = Task { await vm.setPartProgram(6, forPartIndex: 0) }
        for _ in 0 ..< 5 { await Task.yield() }
        #expect(vm.preferences.staffProgramOverrides[address] == 6)

        vm.cancelLoadingSoundfonts()
        _ = await pick.value

        #expect(vm.preferences.staffProgramOverrides[address] == nil)
        #expect(vm.effectiveProgram(forPartIndex: 0) == 40)
        let calls = controller.staffInstrumentCalls.filter { $0.program == 6 }
        #expect(calls.isEmpty)
    }

    @Test func secondInstrumentPickCancelsFirstAndKeepsOriginalAsRevertTarget() async {
        let item = Self.makeItem()
        let repo = FakeScoreLibraryRepository()
        repo.scoreItems = [item]
        let score = Score(
            division: 480,
            parts: [
                Part(
                    id: "P0", trackName: "Vn",
                    instrument: Instrument(id: "v", channels: [InstrumentChannel(program: 40)]),
                    staves: [Staff()]
                ),
            ],
            metaTags: [:]
        )
        let controller = FakePlaybackController()
        controller.blocksPrefetchUntilCancelled = true
        let vm = ReaderViewModel(
            scoreItem: item, repository: repo, gateway: Self.makeGateway(score: score),
            scoresDirectory: URL(filePath: "/tmp"),
            playbackController: controller
        )
        await vm.load()

        let firstPick = Task { await vm.setPartProgram(6, forPartIndex: 0) }
        for _ in 0 ..< 5 { await Task.yield() }

        let secondPick = Task { await vm.setPartProgram(24, forPartIndex: 0) }
        for _ in 0 ..< 10 { await Task.yield() }
        _ = await firstPick.value

        vm.cancelLoadingSoundfonts()
        _ = await secondPick.value

        let address = StaffAddress(partIndex: 0, staffIndexInPart: 0)
        #expect(vm.preferences.staffProgramOverrides[address] == nil)
        #expect(vm.effectiveProgram(forPartIndex: 0) == 40)
    }

    @Test func secondInstrumentPickInheritsWasPlayingFromFirstPick() async {
        let item = Self.makeItem()
        let repo = FakeScoreLibraryRepository()
        repo.scoreItems = [item]
        let score = Score(
            division: 480,
            parts: [
                Part(
                    id: "P0", trackName: "Vn",
                    instrument: Instrument(id: "v", channels: [InstrumentChannel(program: 40)]),
                    staves: [Staff()]
                ),
            ],
            metaTags: [:]
        )
        let controller = FakePlaybackController()
        controller.cachedPatches = [SoundfontPatchKey(bank: 0, program: 40, isDrums: false)]
        controller.soundfontsAvailableLocally = true
        let vm = ReaderViewModel(
            scoreItem: item, repository: repo, gateway: Self.makeGateway(score: score),
            scoresDirectory: URL(filePath: "/tmp"),
            playbackController: controller,
            reachability: FakeNetworkReachability(online: true)
        )
        await vm.load()
        await vm.togglePlayback()
        #expect(vm.isPlaying)

        controller.blocksPrefetchUntilCancelled = true
        let firstPick = Task { await vm.setPartProgram(6, forPartIndex: 0) }
        for _ in 0 ..< 5 { await Task.yield() }
        #expect(!vm.isPlaying)
        #expect(vm.soundfontAlertKind == .loading)

        controller.blocksPrefetchUntilCancelled = false
        let secondPick = Task { await vm.setPartProgram(24, forPartIndex: 0) }
        _ = await firstPick.value
        _ = await secondPick.value

        #expect(vm.isPlaying)
        let calls = controller.staffInstrumentCalls.filter { $0.program == 24 }
        #expect(calls.count == 1)
    }

    @Test func togglePlaybackDuringSilentInstrumentPrefetchShowsLoadingAlert() async {
        let item = Self.makeItem()
        let repo = FakeScoreLibraryRepository()
        repo.scoreItems = [item]
        let score = Score(
            division: 480,
            parts: [
                Part(
                    id: "P0", trackName: "Vn",
                    instrument: Instrument(id: "v", channels: [InstrumentChannel(program: 40)]),
                    staves: [Staff()]
                ),
            ],
            metaTags: [:]
        )
        let controller = FakePlaybackController()
        controller.soundfontsAvailableLocally = true
        controller.blocksPrefetchUntilCancelled = true
        let reachability = FakeNetworkReachability(online: true)
        let vm = ReaderViewModel(
            scoreItem: item, repository: repo, gateway: Self.makeGateway(score: score),
            scoresDirectory: URL(filePath: "/tmp"),
            playbackController: controller,
            reachability: reachability
        )
        await vm.load()

        let pick = Task { await vm.setPartProgram(6, forPartIndex: 0) }
        for _ in 0 ..< 5 { await Task.yield() }
        #expect(vm.soundfontAlertKind == nil)

        let toggle = Task { await vm.togglePlayback() }
        for _ in 0 ..< 5 { await Task.yield() }
        #expect(vm.soundfontAlertKind == .loading)

        vm.cancelLoadingSoundfonts()
        _ = await toggle.value
        _ = await pick.value
        #expect(vm.soundfontAlertKind == nil)
    }

    @Test func togglePlaybackAfterSilentPrefetchSucceedsBeginsPlayback() async {
        let item = Self.makeItem()
        let repo = FakeScoreLibraryRepository()
        repo.scoreItems = [item]
        let score = Score(
            division: 480,
            parts: [
                Part(
                    id: "P0", trackName: "Vn",
                    instrument: Instrument(id: "v", channels: [InstrumentChannel(program: 40)]),
                    staves: [Staff()]
                ),
            ],
            metaTags: [:]
        )
        let controller = FakePlaybackController()
        controller.soundfontsAvailableLocally = true
        let vm = ReaderViewModel(
            scoreItem: item, repository: repo, gateway: Self.makeGateway(score: score),
            scoresDirectory: URL(filePath: "/tmp"),
            playbackController: controller,
            reachability: FakeNetworkReachability(online: true)
        )
        await vm.load()
        await vm.setPartProgram(6, forPartIndex: 0)

        await vm.togglePlayback()
        #expect(vm.isPlaying)
        #expect(controller.playCount == 1)
    }

    @Test func engineSeedUsesPersistedOverrideOverMscx() async throws {
        let item = Self.makeItem()
        let repo = FakeScoreLibraryRepository()
        repo.scoreItems = [item]
        let address = StaffAddress(partIndex: 0, staffIndexInPart: 0)
        repo.storedReaderPreferences[item.id] = ReaderPreferences(
            scoreItemID: item.id,
            staffSize: 14,
            hiddenStaves: [],
            staffVolumeOverrides: [address: 0.3]
        )
        let score = Score(
            division: 480,
            parts: [
                Part(
                    id: "P0", trackName: "Vn",
                    instrument: Instrument(id: "v", channels: [InstrumentChannel(volume: 100)]),
                    staves: [Staff()]
                ),
            ],
            metaTags: [:]
        )
        let controller = FakePlaybackController()
        let vm = ReaderViewModel(
            scoreItem: item, repository: repo, gateway: Self.makeGateway(score: score),
            scoresDirectory: URL(filePath: "/tmp"),
            playbackController: controller
        )
        await vm.load()
        await vm.prepareForPlayback()

        let seeded = try #require(controller.lastLoadedPreferences)
        let staff0 = try #require(seeded.perStaff.first { $0.staffIndex == 0 })
        #expect(staff0.volume == 0.3)
    }

    @Test func engineSeedUsesMscxWhenNoOverride() async throws {
        let item = Self.makeItem()
        let repo = FakeScoreLibraryRepository()
        repo.scoreItems = [item]
        let score = Score(
            division: 480,
            parts: [
                Part(
                    id: "P0", trackName: "Vn",
                    instrument: Instrument(id: "v", channels: [InstrumentChannel(volume: 80)]),
                    staves: [Staff()]
                ),
            ],
            metaTags: [:]
        )
        let controller = FakePlaybackController()
        let vm = ReaderViewModel(
            scoreItem: item, repository: repo, gateway: Self.makeGateway(score: score),
            scoresDirectory: URL(filePath: "/tmp"),
            playbackController: controller
        )
        await vm.load()
        await vm.prepareForPlayback()

        let seeded = try #require(controller.lastLoadedPreferences)
        let staff0 = try #require(seeded.perStaff.first { $0.staffIndex == 0 })
        #expect(abs(staff0.volume - 80.0 / 127.0) < 0.0001)
    }
}

// swiftlint:enable file_length type_body_length
