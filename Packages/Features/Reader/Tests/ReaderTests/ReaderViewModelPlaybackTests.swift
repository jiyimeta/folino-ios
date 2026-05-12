import Domain
import Foundation
@testable import Reader
import SheetMusicCore
import Testing

@MainActor
struct ReaderViewModelPlaybackTests {
    private static func makeItem() -> ScoreItem {
        ScoreItem(
            title: "Test", composer: nil, instrumentationSummary: nil,
            localFileName: "test.mscx", contentHash: "hash",
            sizeBytes: 0, lengthBeats: 0, defaultTempoBpm: 120, primaryKey: nil,
            addedAt: Date(timeIntervalSince1970: 1_700_000_000),
            lastOpenedAt: nil, tagIDs: [], isFavorite: false,
        )
    }

    private static func makeGateway(score: Score) -> FakeScoreFileGateway {
        FakeScoreFileGateway(loadScoreResult: .success((
            score: score,
            summary: ScoreFileSummary(
                title: "Test", composer: nil, instrumentationSummary: "",
                lengthBeats: 0, defaultTempoBpm: 120, primaryKey: nil,
            ),
        )))
    }

    @Test func `playback cursor mirrors controller stream`() {
        let item = Self.makeItem()
        let repo = FakeScoreLibraryRepository()
        repo.scoreItems = [item]
        let controller = FakePlaybackController()
        let vm = ReaderViewModel(
            scoreItem: item, repository: repo,
            gateway: FakeScoreFileGateway(),
            scoresDirectory: URL(filePath: "/tmp"),
            playbackController: controller,
        )
        vm.startObservingCursor()
        let target = ScoreCursor.beat(measureIndex: 4, tickInMeasure: 240)
        controller.emitCursor(target)
        #expect(vm.playbackCursor == target)

        controller.emitCursor(nil)
        #expect(vm.playbackCursor == nil)
    }

    @Test func `cursor becoming nil after play resets is playing`() async {
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
            metaTags: [:],
        )
        let controller = FakePlaybackController()
        let vm = ReaderViewModel(
            scoreItem: item, repository: repo, gateway: Self.makeGateway(score: score),
            scoresDirectory: URL(filePath: "/tmp"),
            playbackController: controller,
        )
        await vm.load()
        vm.startObservingCursor()
        await vm.togglePlayback()
        #expect(vm.isPlaying)

        controller.emitCursor(nil)
        #expect(!vm.isPlaying)
    }

    @Test func `toggle playback loads plays then pauses`() async {
        let item = Self.makeItem()
        let repo = FakeScoreLibraryRepository()
        repo.scoreItems = [item]
        let score = Score(
            division: 480,
            parts: [Part(id: "P0", trackName: "Vn", instrument: Instrument(id: "v"), staves: [Staff()])],
            metaTags: [:],
        )
        let controller = FakePlaybackController()
        let vm = ReaderViewModel(
            scoreItem: item, repository: repo, gateway: Self.makeGateway(score: score),
            scoresDirectory: URL(filePath: "/tmp"),
            playbackController: controller,
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

    @Test func `cancel loading soundfonts aborts toggle playback`() async {
        let item = Self.makeItem()
        let repo = FakeScoreLibraryRepository()
        repo.scoreItems = [item]
        let score = Score(
            division: 480,
            parts: [Part(id: "P0", trackName: "Vn", instrument: Instrument(id: "v"), staves: [Staff()])],
            metaTags: [:],
        )
        let controller = FakePlaybackController()
        controller.blocksLoadUntilCancelled = true
        let vm = ReaderViewModel(
            scoreItem: item, repository: repo, gateway: Self.makeGateway(score: score),
            scoresDirectory: URL(filePath: "/tmp"),
            playbackController: controller,
        )
        await vm.load()

        let toggle = Task { await vm.togglePlayback() }
        for _ in 0 ..< 5 {
            await Task.yield()
        }
        #expect(vm.isLoadingSoundfonts)
        #expect(!vm.isPlaying)
        #expect(controller.loadCount == 0)

        vm.cancelLoadingSoundfonts()
        _ = await toggle.value
        #expect(!vm.isLoadingSoundfonts)
        #expect(!vm.isPlaying)
        #expect(controller.playCount == 0)
    }

    @Test func `prepare for playback primes engine without showing alert`() async {
        let item = Self.makeItem()
        let repo = FakeScoreLibraryRepository()
        repo.scoreItems = [item]
        let score = Score(
            division: 480,
            parts: [Part(id: "P0", trackName: "Vn", instrument: Instrument(id: "v"), staves: [Staff()])],
            metaTags: [:],
        )
        let controller = FakePlaybackController()
        let vm = ReaderViewModel(
            scoreItem: item, repository: repo, gateway: Self.makeGateway(score: score),
            scoresDirectory: URL(filePath: "/tmp"),
            playbackController: controller,
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

    @Test func `toggle playback shows offline alert when offline and uncached`() async {
        let item = Self.makeItem()
        let repo = FakeScoreLibraryRepository()
        repo.scoreItems = [item]
        let score = Score(
            division: 480,
            parts: [Part(id: "P0", trackName: "Vn", instrument: Instrument(id: "v"), staves: [Staff()])],
            metaTags: [:],
        )
        let controller = FakePlaybackController()
        controller.soundfontsAvailableLocally = false
        controller.blocksLoadUntilCancelled = true
        let reachability = FakeNetworkReachability(online: false)
        let vm = ReaderViewModel(
            scoreItem: item, repository: repo, gateway: Self.makeGateway(score: score),
            scoresDirectory: URL(filePath: "/tmp"),
            playbackController: controller,
            reachability: reachability,
        )
        await vm.load()

        let toggle = Task { await vm.togglePlayback() }
        for _ in 0 ..< 5 {
            await Task.yield()
        }
        #expect(vm.soundfontAlertKind == .offline)
        #expect(!vm.isLoadingSoundfonts)

        vm.cancelLoadingSoundfonts()
        _ = await toggle.value
        #expect(vm.soundfontAlertKind == nil)
    }

    @Test func `toggle playback shows loading alert when online and uncached`() async {
        let item = Self.makeItem()
        let repo = FakeScoreLibraryRepository()
        repo.scoreItems = [item]
        let score = Score(
            division: 480,
            parts: [Part(id: "P0", trackName: "Vn", instrument: Instrument(id: "v"), staves: [Staff()])],
            metaTags: [:],
        )
        let controller = FakePlaybackController()
        controller.soundfontsAvailableLocally = false
        controller.blocksLoadUntilCancelled = true
        let reachability = FakeNetworkReachability(online: true)
        let vm = ReaderViewModel(
            scoreItem: item, repository: repo, gateway: Self.makeGateway(score: score),
            scoresDirectory: URL(filePath: "/tmp"),
            playbackController: controller,
            reachability: reachability,
        )
        await vm.load()

        let toggle = Task { await vm.togglePlayback() }
        for _ in 0 ..< 5 {
            await Task.yield()
        }
        #expect(vm.soundfontAlertKind == .loading)

        vm.cancelLoadingSoundfonts()
        _ = await toggle.value
        #expect(vm.soundfontAlertKind == nil)
    }

    @Test func `toggle playback skips alert when soundfonts are cached`() async {
        let item = Self.makeItem()
        let repo = FakeScoreLibraryRepository()
        repo.scoreItems = [item]
        let score = Score(
            division: 480,
            parts: [Part(id: "P0", trackName: "Vn", instrument: Instrument(id: "v"), staves: [Staff()])],
            metaTags: [:],
        )
        let controller = FakePlaybackController()
        controller.soundfontsAvailableLocally = true
        controller.blocksLoadUntilCancelled = true
        let vm = ReaderViewModel(
            scoreItem: item, repository: repo, gateway: Self.makeGateway(score: score),
            scoresDirectory: URL(filePath: "/tmp"),
            playbackController: controller,
        )
        await vm.load()

        let toggle = Task { await vm.togglePlayback() }
        for _ in 0 ..< 5 {
            await Task.yield()
        }
        // Even though `load` is blocked, the alert never shows because the
        // controller reports the cache covers the score.
        #expect(!vm.isLoadingSoundfonts)

        vm.cancelLoadingSoundfonts()
        _ = await toggle.value
        #expect(!vm.isLoadingSoundfonts)
        #expect(!vm.isPlaying)
    }

    @Test func `toggle playback is no op when score not loaded`() async {
        let item = Self.makeItem()
        let repo = FakeScoreLibraryRepository()
        repo.scoreItems = [item]
        let controller = FakePlaybackController()
        let vm = ReaderViewModel(
            scoreItem: item, repository: repo,
            gateway: FakeScoreFileGateway(),
            scoresDirectory: URL(filePath: "/tmp"),
            playbackController: controller,
        )
        // No `await vm.load()`.
        await vm.togglePlayback()
        #expect(controller.loadCount == 0)
        #expect(controller.playCount == 0)
        #expect(!vm.isPlaying)
    }

    @Test func `toggle staff solo flips membership and forwards to controller`() async {
        let item = Self.makeItem()
        let repo = FakeScoreLibraryRepository()
        repo.scoreItems = [item]
        let score = Score(
            division: 480,
            parts: [
                Part(id: "P0", trackName: "Vn", instrument: Instrument(id: "v"), staves: [Staff()]),
                Part(id: "P1", trackName: "Pno", instrument: Instrument(id: "p"), staves: [Staff(), Staff()]),
            ],
            metaTags: [:],
        )
        let controller = FakePlaybackController()
        let vm = ReaderViewModel(
            scoreItem: item, repository: repo, gateway: Self.makeGateway(score: score),
            scoresDirectory: URL(filePath: "/tmp"),
            playbackController: controller,
        )
        await vm.load()

        // Piano top staff → flat index 1 (Vn=0, Pno-top=1, Pno-bottom=2).
        let pianoTop = StaffAddress(partIndex: 1, staffIndexInPart: 0)
        vm.mixerModel.toggleStaffSolo(pianoTop)
        #expect(vm.mixerModel.soloStaves == [pianoTop])
        for _ in 0 ..< 5 {
            await Task.yield()
        }
        #expect(controller.staffSoloStates[1] == true)

        vm.mixerModel.toggleStaffSolo(pianoTop)
        #expect(vm.mixerModel.soloStaves.isEmpty)
        for _ in 0 ..< 5 {
            await Task.yield()
        }
        #expect(controller.staffSoloStates[1] == false)
    }

    @Test func `toggle staff solo is no op when score not loaded`() async {
        let item = Self.makeItem()
        let repo = FakeScoreLibraryRepository()
        repo.scoreItems = [item]
        let controller = FakePlaybackController()
        let vm = ReaderViewModel(
            scoreItem: item, repository: repo,
            gateway: FakeScoreFileGateway(),
            scoresDirectory: URL(filePath: "/tmp"),
            playbackController: controller,
        )
        // No load: flat index lookup fails, controller is never called,
        // but the in-memory set still tracks the user's intent.
        let address = StaffAddress(partIndex: 0, staffIndexInPart: 0)
        vm.mixerModel.toggleStaffSolo(address)
        #expect(vm.mixerModel.soloStaves == [address])
        for _ in 0 ..< 5 {
            await Task.yield()
        }
        #expect(controller.staffSoloStates.isEmpty)
    }

    @Test func `effective program falls back to score instrument channel`() async {
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
                    staves: [Staff()],
                ),
                Part(
                    id: "P1", trackName: "Pno",
                    instrument: Instrument(id: "p", channels: [pianoChannel]),
                    staves: [Staff(), Staff()],
                ),
            ],
            metaTags: [:],
        )
        let vm = ReaderViewModel(
            scoreItem: item, repository: repo, gateway: Self.makeGateway(score: score),
            scoresDirectory: URL(filePath: "/tmp"),
        )
        await vm.load()

        let violinAddress = StaffAddress(partIndex: 0, staffIndexInPart: 0)
        let pianoTopAddress = StaffAddress(partIndex: 1, staffIndexInPart: 0)
        #expect(vm.mixerModel.effectiveProgram(for: violinAddress) == 40)
        #expect(vm.mixerModel.effectiveProgram(for: pianoTopAddress) == 0)
        #expect(!vm.mixerModel.hasProgramOverride(for: violinAddress))
    }

    @Test func `set staff program persists override and forwards to controller`() async {
        let item = Self.makeItem()
        let repo = FakeScoreLibraryRepository()
        repo.scoreItems = [item]
        let score = Score(
            division: 480,
            parts: [
                Part(
                    id: "P0", trackName: "Vn",
                    instrument: Instrument(id: "v", channels: [InstrumentChannel(program: 40)]),
                    staves: [Staff()],
                ),
            ],
            metaTags: [:],
        )
        let controller = FakePlaybackController()
        let vm = ReaderViewModel(
            scoreItem: item, repository: repo, gateway: Self.makeGateway(score: score),
            scoresDirectory: URL(filePath: "/tmp"),
            playbackController: controller,
        )
        await vm.load()

        let address = StaffAddress(partIndex: 0, staffIndexInPart: 0)
        await vm.mixerModel.setStaffProgram(6, for: address) // Harpsichord
        #expect(vm.mixerModel.effectiveProgram(for: address) == 6)
        #expect(vm.mixerModel.hasProgramOverride(for: address))
        #expect(vm.mixerModel.staffProgramOverrides[address] == 6)
        // Saved to repository.
        let saved = try? #require(repo.savedReaderPreferences.last)
        #expect(saved?.staffProgramOverrides[address] == 6)
        // Forwarded to the controller with bank 0.
        let call = try? #require(controller.staffInstrumentCalls.last)
        #expect(call?.staff == 0)
        #expect(call?.bank == 0)
        #expect(call?.program == 6)
    }

    @Test func `clear staff program override reverts to score default`() async {
        let item = Self.makeItem()
        let repo = FakeScoreLibraryRepository()
        repo.scoreItems = [item]
        let score = Score(
            division: 480,
            parts: [
                Part(
                    id: "P0", trackName: "Vn",
                    instrument: Instrument(id: "v", channels: [InstrumentChannel(program: 40)]),
                    staves: [Staff()],
                ),
            ],
            metaTags: [:],
        )
        let controller = FakePlaybackController()
        let vm = ReaderViewModel(
            scoreItem: item, repository: repo, gateway: Self.makeGateway(score: score),
            scoresDirectory: URL(filePath: "/tmp"),
            playbackController: controller,
        )
        await vm.load()

        let address = StaffAddress(partIndex: 0, staffIndexInPart: 0)
        await vm.mixerModel.setStaffProgram(6, for: address)
        await vm.mixerModel.clearStaffProgramOverride(for: address)

        #expect(!vm.mixerModel.hasProgramOverride(for: address))
        #expect(vm.mixerModel.effectiveProgram(for: address) == 40)
        #expect(vm.mixerModel.staffProgramOverrides[address] == nil)
        let lastCall = try? #require(controller.staffInstrumentCalls.last)
        #expect(lastCall?.program == 40) // reset call uses score default
    }

    @Test func `initial playback preferences use overrides and score defaults`() async throws {
        let item = Self.makeItem()
        let repo = FakeScoreLibraryRepository()
        repo.scoreItems = [item]
        let address2 = StaffAddress(partIndex: 1, staffIndexInPart: 0)
        repo.storedReaderPreferences[item.id] = ReaderPreferences(
            scoreItemID: item.id, staffSize: 14, hiddenStaves: [],
            staffProgramOverrides: [address2: 24], // Acoustic Guitar
        )
        let score = Score(
            division: 480,
            parts: [
                Part(
                    id: "P0", trackName: "Vn",
                    instrument: Instrument(id: "v", channels: [InstrumentChannel(program: 40)]),
                    staves: [Staff()],
                ),
                Part(
                    id: "P1", trackName: "Pno",
                    instrument: Instrument(id: "p", channels: [InstrumentChannel(program: 0)]),
                    staves: [Staff()],
                ),
            ],
            metaTags: [:],
        )
        let controller = FakePlaybackController()
        let vm = ReaderViewModel(
            scoreItem: item, repository: repo, gateway: Self.makeGateway(score: score),
            scoresDirectory: URL(filePath: "/tmp"),
            playbackController: controller,
        )
        await vm.load()
        await vm.togglePlayback()

        let prefs = try #require(controller.lastLoadedPreferences)
        #expect(prefs.perStaff[0].gmProgram == 40) // violin uses score default
        #expect(prefs.perStaff[1].gmProgram == 24) // piano uses override
    }

    @Test func `set volume forwards to controller by flat staff index`() async {
        let item = Self.makeItem()
        let repo = FakeScoreLibraryRepository()
        repo.scoreItems = [item]
        let score = Score(
            division: 480,
            parts: [
                Part(id: "P0", trackName: "Vn", instrument: Instrument(id: "v"), staves: [Staff()]),
                Part(id: "P1", trackName: "Pno", instrument: Instrument(id: "p"), staves: [Staff(), Staff()]),
            ],
            metaTags: [:],
        )
        let controller = FakePlaybackController()
        let vm = ReaderViewModel(
            scoreItem: item, repository: repo, gateway: Self.makeGateway(score: score),
            scoresDirectory: URL(filePath: "/tmp"),
            playbackController: controller,
        )
        await vm.load()

        // Piano's lower staff is at (partIndex: 1, staffIndexInPart: 1)
        // → flat staff index 2 (Vn=0, Pno-top=1, Pno-bottom=2).
        let pianoBottom = StaffAddress(partIndex: 1, staffIndexInPart: 1)
        vm.mixerModel.setVolume(0.3, for: pianoBottom)
        await Task.yield()
        await Task.yield()
        #expect(controller.staffVolumes[2] == 0.3)
    }

    @Test func `set part program with cached patch skips prefetch`() async {
        let item = Self.makeItem()
        let repo = FakeScoreLibraryRepository()
        repo.scoreItems = [item]
        let score = Score(
            division: 480,
            parts: [
                Part(
                    id: "P0", trackName: "Vn",
                    instrument: Instrument(id: "v", channels: [InstrumentChannel(program: 40)]),
                    staves: [Staff()],
                ),
            ],
            metaTags: [:],
        )
        let controller = FakePlaybackController()
        controller.cachedPatches = [SoundfontPatchKey(bank: 0, program: 6, isDrums: false)]
        let vm = ReaderViewModel(
            scoreItem: item, repository: repo, gateway: Self.makeGateway(score: score),
            scoresDirectory: URL(filePath: "/tmp"),
            playbackController: controller,
        )
        await vm.load()

        await vm.mixerModel.setPartProgram(6, forPartIndex: 0)

        #expect(controller.prefetchedPatches.isEmpty)
        #expect(vm.soundfontAlertKind == nil)
        let calls = controller.staffInstrumentCalls.filter { $0.program == 6 }
        #expect(calls.count == 1)
    }

    @Test func `set part program with uncached patch prefetches silently when not playing`() async {
        let item = Self.makeItem()
        let repo = FakeScoreLibraryRepository()
        repo.scoreItems = [item]
        let score = Score(
            division: 480,
            parts: [
                Part(
                    id: "P0", trackName: "Vn",
                    instrument: Instrument(id: "v", channels: [InstrumentChannel(program: 40)]),
                    staves: [Staff()],
                ),
            ],
            metaTags: [:],
        )
        let controller = FakePlaybackController()
        // cachedPatches deliberately empty — every pick is a miss.
        let vm = ReaderViewModel(
            scoreItem: item, repository: repo, gateway: Self.makeGateway(score: score),
            scoresDirectory: URL(filePath: "/tmp"),
            playbackController: controller,
        )
        await vm.load()

        await vm.mixerModel.setPartProgram(6, forPartIndex: 0)

        #expect(vm.soundfontAlertKind == nil)
        #expect(controller.prefetchedPatches.contains(
            SoundfontPatchKey(bank: 0, program: 6, isDrums: false),
        ))
        // Engine reflection happens after prefetch resolves.
        let calls = controller.staffInstrumentCalls.filter { $0.program == 6 }
        #expect(calls.count == 1)
        #expect(vm.mixerModel.staffProgramOverrides[
            StaffAddress(partIndex: 0, staffIndexInPart: 0),
        ] == 6)
    }

    @Test func `set part program during playback pauses and shows loading alert`() async {
        let item = Self.makeItem()
        let repo = FakeScoreLibraryRepository()
        repo.scoreItems = [item]
        let score = Score(
            division: 480,
            parts: [
                Part(
                    id: "P0", trackName: "Vn",
                    instrument: Instrument(id: "v", channels: [InstrumentChannel(program: 40)]),
                    staves: [Staff()],
                ),
            ],
            metaTags: [:],
        )
        let controller = FakePlaybackController()
        controller.cachedPatches = [SoundfontPatchKey(bank: 0, program: 40, isDrums: false)]
        controller.blocksPrefetchUntilCancelled = true
        let reachability = FakeNetworkReachability(online: true)
        let vm = ReaderViewModel(
            scoreItem: item, repository: repo, gateway: Self.makeGateway(score: score),
            scoresDirectory: URL(filePath: "/tmp"),
            playbackController: controller,
            reachability: reachability,
        )
        await vm.load()
        controller.soundfontsAvailableLocally = true
        await vm.togglePlayback()
        #expect(vm.isPlaying)

        let pick = Task { await vm.mixerModel.setPartProgram(6, forPartIndex: 0) }
        for _ in 0 ..< 5 {
            await Task.yield()
        }
        #expect(!vm.isPlaying)
        #expect(vm.soundfontAlertKind == .loading)
        #expect(controller.pauseCount == 1)

        vm.cancelLoadingSoundfonts()
        _ = await pick.value
        #expect(vm.soundfontAlertKind == nil)
    }

    @Test func `set part program during playback resumes after prefetch succeeds`() async {
        let item = Self.makeItem()
        let repo = FakeScoreLibraryRepository()
        repo.scoreItems = [item]
        let score = Score(
            division: 480,
            parts: [
                Part(
                    id: "P0", trackName: "Vn",
                    instrument: Instrument(id: "v", channels: [InstrumentChannel(program: 40)]),
                    staves: [Staff()],
                ),
            ],
            metaTags: [:],
        )
        let controller = FakePlaybackController()
        controller.cachedPatches = [SoundfontPatchKey(bank: 0, program: 40, isDrums: false)]
        let reachability = FakeNetworkReachability(online: true)
        let vm = ReaderViewModel(
            scoreItem: item, repository: repo, gateway: Self.makeGateway(score: score),
            scoresDirectory: URL(filePath: "/tmp"),
            playbackController: controller,
            reachability: reachability,
        )
        await vm.load()
        controller.soundfontsAvailableLocally = true
        await vm.togglePlayback()
        let playsBefore = controller.playCount
        #expect(vm.isPlaying)

        await vm.mixerModel.setPartProgram(6, forPartIndex: 0)

        #expect(vm.isPlaying)
        #expect(controller.playCount == playsBefore + 1)
        #expect(controller.pauseCount == 1)
        let calls = controller.staffInstrumentCalls.filter { $0.program == 6 }
        #expect(calls.count == 1)
    }

    @Test func `set part program during playback shows offline alert when offline`() async {
        let item = Self.makeItem()
        let repo = FakeScoreLibraryRepository()
        repo.scoreItems = [item]
        let score = Score(
            division: 480,
            parts: [
                Part(
                    id: "P0", trackName: "Vn",
                    instrument: Instrument(id: "v", channels: [InstrumentChannel(program: 40)]),
                    staves: [Staff()],
                ),
            ],
            metaTags: [:],
        )
        let controller = FakePlaybackController()
        controller.cachedPatches = [SoundfontPatchKey(bank: 0, program: 40, isDrums: false)]
        controller.blocksPrefetchUntilCancelled = true
        let reachability = FakeNetworkReachability(online: false)
        let vm = ReaderViewModel(
            scoreItem: item, repository: repo, gateway: Self.makeGateway(score: score),
            scoresDirectory: URL(filePath: "/tmp"),
            playbackController: controller,
            reachability: reachability,
        )
        await vm.load()
        controller.soundfontsAvailableLocally = true
        await vm.togglePlayback()

        let pick = Task { await vm.mixerModel.setPartProgram(6, forPartIndex: 0) }
        for _ in 0 ..< 5 {
            await Task.yield()
        }
        #expect(vm.soundfontAlertKind == .offline)

        vm.cancelLoadingSoundfonts()
        _ = await pick.value
    }

    @Test func `cancel during instrument prefetch reverts program override`() async {
        let item = Self.makeItem()
        let repo = FakeScoreLibraryRepository()
        repo.scoreItems = [item]
        let score = Score(
            division: 480,
            parts: [
                Part(
                    id: "P0", trackName: "Vn",
                    instrument: Instrument(id: "v", channels: [InstrumentChannel(program: 40)]),
                    staves: [Staff()],
                ),
            ],
            metaTags: [:],
        )
        let controller = FakePlaybackController()
        controller.blocksPrefetchUntilCancelled = true
        let vm = ReaderViewModel(
            scoreItem: item, repository: repo, gateway: Self.makeGateway(score: score),
            scoresDirectory: URL(filePath: "/tmp"),
            playbackController: controller,
        )
        await vm.load()

        let address = StaffAddress(partIndex: 0, staffIndexInPart: 0)
        let pick = Task { await vm.mixerModel.setPartProgram(6, forPartIndex: 0) }
        for _ in 0 ..< 5 {
            await Task.yield()
        }
        #expect(vm.mixerModel.staffProgramOverrides[address] == 6)

        vm.cancelLoadingSoundfonts()
        _ = await pick.value

        #expect(vm.mixerModel.staffProgramOverrides[address] == nil)
        #expect(vm.mixerModel.effectiveProgram(forPartIndex: 0) == 40)
        let calls = controller.staffInstrumentCalls.filter { $0.program == 6 }
        #expect(calls.isEmpty)
    }

    @Test func `second instrument pick cancels first and keeps original as revert target`() async {
        let item = Self.makeItem()
        let repo = FakeScoreLibraryRepository()
        repo.scoreItems = [item]
        let score = Score(
            division: 480,
            parts: [
                Part(
                    id: "P0", trackName: "Vn",
                    instrument: Instrument(id: "v", channels: [InstrumentChannel(program: 40)]),
                    staves: [Staff()],
                ),
            ],
            metaTags: [:],
        )
        let controller = FakePlaybackController()
        controller.blocksPrefetchUntilCancelled = true
        let vm = ReaderViewModel(
            scoreItem: item, repository: repo, gateway: Self.makeGateway(score: score),
            scoresDirectory: URL(filePath: "/tmp"),
            playbackController: controller,
        )
        await vm.load()

        let firstPick = Task { await vm.mixerModel.setPartProgram(6, forPartIndex: 0) }
        for _ in 0 ..< 5 {
            await Task.yield()
        }

        let secondPick = Task { await vm.mixerModel.setPartProgram(24, forPartIndex: 0) }
        for _ in 0 ..< 10 {
            await Task.yield()
        }
        _ = await firstPick.value

        vm.cancelLoadingSoundfonts()
        _ = await secondPick.value

        let address = StaffAddress(partIndex: 0, staffIndexInPart: 0)
        #expect(vm.mixerModel.staffProgramOverrides[address] == nil)
        #expect(vm.mixerModel.effectiveProgram(forPartIndex: 0) == 40)
    }

    @Test func `second instrument pick inherits was playing from first pick`() async {
        let item = Self.makeItem()
        let repo = FakeScoreLibraryRepository()
        repo.scoreItems = [item]
        let score = Score(
            division: 480,
            parts: [
                Part(
                    id: "P0", trackName: "Vn",
                    instrument: Instrument(id: "v", channels: [InstrumentChannel(program: 40)]),
                    staves: [Staff()],
                ),
            ],
            metaTags: [:],
        )
        let controller = FakePlaybackController()
        controller.cachedPatches = [SoundfontPatchKey(bank: 0, program: 40, isDrums: false)]
        controller.soundfontsAvailableLocally = true
        let vm = ReaderViewModel(
            scoreItem: item, repository: repo, gateway: Self.makeGateway(score: score),
            scoresDirectory: URL(filePath: "/tmp"),
            playbackController: controller,
            reachability: FakeNetworkReachability(online: true),
        )
        await vm.load()
        await vm.togglePlayback()
        #expect(vm.isPlaying)

        controller.blocksPrefetchUntilCancelled = true
        let firstPick = Task { await vm.mixerModel.setPartProgram(6, forPartIndex: 0) }
        for _ in 0 ..< 5 {
            await Task.yield()
        }
        #expect(!vm.isPlaying)
        #expect(vm.soundfontAlertKind == .loading)

        controller.blocksPrefetchUntilCancelled = false
        let secondPick = Task { await vm.mixerModel.setPartProgram(24, forPartIndex: 0) }
        _ = await firstPick.value
        _ = await secondPick.value

        #expect(vm.isPlaying)
        let calls = controller.staffInstrumentCalls.filter { $0.program == 24 }
        #expect(calls.count == 1)
    }

    @Test func `toggle playback during silent instrument prefetch shows loading alert`() async {
        let item = Self.makeItem()
        let repo = FakeScoreLibraryRepository()
        repo.scoreItems = [item]
        let score = Score(
            division: 480,
            parts: [
                Part(
                    id: "P0", trackName: "Vn",
                    instrument: Instrument(id: "v", channels: [InstrumentChannel(program: 40)]),
                    staves: [Staff()],
                ),
            ],
            metaTags: [:],
        )
        let controller = FakePlaybackController()
        controller.soundfontsAvailableLocally = true
        controller.blocksPrefetchUntilCancelled = true
        let reachability = FakeNetworkReachability(online: true)
        let vm = ReaderViewModel(
            scoreItem: item, repository: repo, gateway: Self.makeGateway(score: score),
            scoresDirectory: URL(filePath: "/tmp"),
            playbackController: controller,
            reachability: reachability,
        )
        await vm.load()

        let pick = Task { await vm.mixerModel.setPartProgram(6, forPartIndex: 0) }
        for _ in 0 ..< 5 {
            await Task.yield()
        }
        #expect(vm.soundfontAlertKind == nil)

        let toggle = Task { await vm.togglePlayback() }
        for _ in 0 ..< 5 {
            await Task.yield()
        }
        #expect(vm.soundfontAlertKind == .loading)

        vm.cancelLoadingSoundfonts()
        _ = await toggle.value
        _ = await pick.value
        #expect(vm.soundfontAlertKind == nil)
    }

    @Test func `toggle playback after silent prefetch succeeds begins playback`() async {
        let item = Self.makeItem()
        let repo = FakeScoreLibraryRepository()
        repo.scoreItems = [item]
        let score = Score(
            division: 480,
            parts: [
                Part(
                    id: "P0", trackName: "Vn",
                    instrument: Instrument(id: "v", channels: [InstrumentChannel(program: 40)]),
                    staves: [Staff()],
                ),
            ],
            metaTags: [:],
        )
        let controller = FakePlaybackController()
        controller.soundfontsAvailableLocally = true
        let vm = ReaderViewModel(
            scoreItem: item, repository: repo, gateway: Self.makeGateway(score: score),
            scoresDirectory: URL(filePath: "/tmp"),
            playbackController: controller,
            reachability: FakeNetworkReachability(online: true),
        )
        await vm.load()
        await vm.mixerModel.setPartProgram(6, forPartIndex: 0)

        await vm.togglePlayback()
        #expect(vm.isPlaying)
        #expect(controller.playCount == 1)
    }

    @Test func `engine seed uses persisted override over mscx`() async throws {
        let item = Self.makeItem()
        let repo = FakeScoreLibraryRepository()
        repo.scoreItems = [item]
        let address = StaffAddress(partIndex: 0, staffIndexInPart: 0)
        repo.storedReaderPreferences[item.id] = ReaderPreferences(
            scoreItemID: item.id,
            staffSize: 14,
            hiddenStaves: [],
            staffVolumeOverrides: [address: 0.3],
        )
        let score = Score(
            division: 480,
            parts: [
                Part(
                    id: "P0", trackName: "Vn",
                    instrument: Instrument(id: "v", channels: [InstrumentChannel(volume: 100)]),
                    staves: [Staff()],
                ),
            ],
            metaTags: [:],
        )
        let controller = FakePlaybackController()
        let vm = ReaderViewModel(
            scoreItem: item, repository: repo, gateway: Self.makeGateway(score: score),
            scoresDirectory: URL(filePath: "/tmp"),
            playbackController: controller,
        )
        await vm.load()
        await vm.prepareForPlayback()

        let seeded = try #require(controller.lastLoadedPreferences)
        let staff0 = try #require(seeded.perStaff.first { $0.staffIndex == 0 })
        #expect(staff0.volume == 0.3)
    }

    @Test func `engine seed uses mscx when no override`() async throws {
        let item = Self.makeItem()
        let repo = FakeScoreLibraryRepository()
        repo.scoreItems = [item]
        let score = Score(
            division: 480,
            parts: [
                Part(
                    id: "P0", trackName: "Vn",
                    instrument: Instrument(id: "v", channels: [InstrumentChannel(volume: 80)]),
                    staves: [Staff()],
                ),
            ],
            metaTags: [:],
        )
        let controller = FakePlaybackController()
        let vm = ReaderViewModel(
            scoreItem: item, repository: repo, gateway: Self.makeGateway(score: score),
            scoresDirectory: URL(filePath: "/tmp"),
            playbackController: controller,
        )
        await vm.load()
        await vm.prepareForPlayback()

        let seeded = try #require(controller.lastLoadedPreferences)
        let staff0 = try #require(seeded.perStaff.first { $0.staffIndex == 0 })
        #expect(abs(staff0.volume - 80.0 / 127.0) < 0.0001)
    }
}
