import Domain
import Foundation
@testable import Reader
import SheetMusicCore
import Testing

@MainActor
struct ReaderViewModelPlaybackTests {
    private static let violinStrip = MixerStripID(partIndex: 0, instrumentOrdinal: 0)
    private static let pianoStrip = MixerStripID(partIndex: 1, instrumentOrdinal: 0)

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

    /// A strip as the engine would report it, so a test can stand a prepared engine up without one.
    private static func strip(
        _ id: MixerStripID, name: String, volume: Double = 1.0, program: Int,
    ) -> MixerStrip {
        MixerStrip(
            id: id, partName: name, instrumentName: name,
            defaultVolume: volume, defaultProgram: program, isDrums: false,
        )
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
        vm.playbackSession.startObservingCursor()
        let target = ScoreCursor.beat(measureIndex: 4, tickInMeasure: 240)
        controller.emitCursor(target)
        #expect(vm.playbackSession.playbackCursor == target)

        controller.emitCursor(nil)
        #expect(vm.playbackSession.playbackCursor == nil)
    }

    @Test func `cursor becoming nil after play resets is playing`() async {
        // The engine emits a nil cursor when playback finishes naturally (`PlaybackEngine.stop()` clears
        // `currentCursor` once `tickCursor` reaches `totalTicks`). The toolbar's play/pause glyph is bound to
        // `isPlaying`, so it must flip back to "play" when that signal arrives.
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
        vm.playbackSession.startObservingCursor()
        await vm.playbackSession.togglePlayback()
        #expect(vm.playbackSession.isPlaying)

        controller.emitCursor(nil)
        #expect(!vm.playbackSession.isPlaying)
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

        await vm.playbackSession.togglePlayback()
        #expect(controller.loadCount == 1)
        #expect(controller.playCount == 1)
        #expect(vm.playbackSession.isPlaying)

        await vm.playbackSession.togglePlayback()
        #expect(controller.pauseCount == 1)
        #expect(controller.loadCount == 1) // load only happens once
        #expect(!vm.playbackSession.isPlaying)
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
        await vm.playbackSession.prepareForPlayback()

        #expect(controller.loadCount == 1)

        // First user-driven toggle should reuse the primed engine — no additional load.
        await vm.playbackSession.togglePlayback()
        #expect(controller.loadCount == 1)
        #expect(controller.playCount == 1)
        #expect(vm.playbackSession.isPlaying)
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
        await vm.playbackSession.togglePlayback()
        #expect(controller.loadCount == 0)
        #expect(controller.playCount == 0)
        #expect(!vm.playbackSession.isPlaying)
    }

    /// The mixer's strips are the engine's, so they only exist once a load has landed — and they arrive by BOTH load
    /// paths, `prepareForPlayback` and the `togglePlayback` fallback that runs when the first never completed.
    @Test func `the mixer's strips arrive by whichever load path ran`() async {
        for usesPrepare in [true, false] {
            let item = Self.makeItem()
            let repo = FakeScoreLibraryRepository()
            repo.scoreItems = [item]
            let score = Score(
                division: 480,
                parts: [Part(id: "P0", trackName: "Vn", instrument: Instrument(id: "v"), staves: [Staff()])],
                metaTags: [:],
            )
            let controller = FakePlaybackController()
            controller.strips = [Self.strip(Self.violinStrip, name: "Vn", program: 40)]
            let vm = ReaderViewModel(
                scoreItem: item, repository: repo, gateway: Self.makeGateway(score: score),
                scoresDirectory: URL(filePath: "/tmp"),
                playbackController: controller,
            )
            await vm.load()
            #expect(vm.mixerModel.strips.isEmpty)

            if usesPrepare {
                await vm.playbackSession.prepareForPlayback()
            } else {
                await vm.playbackSession.togglePlayback()
            }

            #expect(vm.mixerModel.strips.map(\.id) == [Self.violinStrip])
        }
    }

    @Test func `toggle solo flips membership and forwards to controller`() async {
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

        vm.mixerModel.toggleSolo(Self.pianoStrip)
        #expect(vm.mixerModel.soloStrips == [Self.pianoStrip])
        for _ in 0 ..< 5 {
            await Task.yield()
        }
        #expect(controller.stripSolos.map(\.strip) == [Self.pianoStrip])
        #expect(controller.stripSolos.map(\.isSolo) == [true])

        vm.mixerModel.toggleSolo(Self.pianoStrip)
        #expect(vm.mixerModel.soloStrips.isEmpty)
        for _ in 0 ..< 5 {
            await Task.yield()
        }
        #expect(controller.stripSolos.map(\.isSolo) == [true, false])
    }

    /// Addressing no longer goes through the score, so there is nothing left to resolve before forwarding: the strip
    /// id goes straight to the controller, which is the only thing that knows whether a score is prepared.
    @Test func `toggle solo forwards even before a score is prepared`() async {
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
        // No load.
        vm.mixerModel.toggleSolo(Self.violinStrip)
        #expect(vm.mixerModel.soloStrips == [Self.violinStrip])
        for _ in 0 ..< 5 {
            await Task.yield()
        }
        #expect(controller.stripSolos.map(\.strip) == [Self.violinStrip])
    }

    @Test func `effective program falls back to the strip's score program`() async {
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
                Part(
                    id: "P1", trackName: "Pno",
                    instrument: Instrument(id: "p", channels: [InstrumentChannel(program: 0)]),
                    staves: [Staff(), Staff()],
                ),
            ],
            metaTags: [:],
        )
        let controller = FakePlaybackController()
        controller.strips = [
            Self.strip(Self.violinStrip, name: "Vn", program: 40), // GM 40 = Violin
            Self.strip(Self.pianoStrip, name: "Pno", program: 0), // GM 0 = Piano
        ]
        let vm = ReaderViewModel(
            scoreItem: item, repository: repo, gateway: Self.makeGateway(score: score),
            scoresDirectory: URL(filePath: "/tmp"),
            playbackController: controller,
        )
        await vm.load()
        await vm.playbackSession.prepareForPlayback()

        #expect(vm.mixerModel.effectiveProgram(for: Self.violinStrip) == 40)
        #expect(vm.mixerModel.effectiveProgram(for: Self.pianoStrip) == 0)
        #expect(!vm.mixerModel.hasProgramOverride(for: Self.violinStrip))
    }

    @Test func `set program persists override and forwards to controller`() async {
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
        controller.strips = [Self.strip(Self.violinStrip, name: "Vn", program: 40)]
        let vm = ReaderViewModel(
            scoreItem: item, repository: repo, gateway: Self.makeGateway(score: score),
            scoresDirectory: URL(filePath: "/tmp"),
            playbackController: controller,
        )
        await vm.load()
        await vm.playbackSession.prepareForPlayback()

        await vm.mixerModel.setProgram(6, for: Self.violinStrip) // Harpsichord
        #expect(vm.mixerModel.effectiveProgram(for: Self.violinStrip) == 6)
        #expect(vm.mixerModel.hasProgramOverride(for: Self.violinStrip))
        #expect(vm.mixerModel.programOverrides[Self.violinStrip] == 6)
        // Saved to repository.
        let saved = try? #require(repo.savedReaderPreferences.last)
        #expect(saved?.stripProgramOverrides[Self.violinStrip] == 6)
        // Forwarded to the controller.
        let call = try? #require(controller.stripPrograms.last)
        #expect(call?.strip == Self.violinStrip)
        #expect(call?.program == 6)
    }

    @Test func `clear program override reverts to the strip's score program`() async {
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
        controller.strips = [Self.strip(Self.violinStrip, name: "Vn", program: 40)]
        let vm = ReaderViewModel(
            scoreItem: item, repository: repo, gateway: Self.makeGateway(score: score),
            scoresDirectory: URL(filePath: "/tmp"),
            playbackController: controller,
        )
        await vm.load()
        await vm.playbackSession.prepareForPlayback()

        await vm.mixerModel.setProgram(6, for: Self.violinStrip)
        await vm.mixerModel.clearProgramOverride(for: Self.violinStrip)

        #expect(!vm.mixerModel.hasProgramOverride(for: Self.violinStrip))
        #expect(vm.mixerModel.effectiveProgram(for: Self.violinStrip) == 40)
        #expect(vm.mixerModel.programOverrides[Self.violinStrip] == nil)
        let lastCall = try? #require(controller.stripPrograms.last)
        #expect(lastCall?.program == 40) // reset call uses the score's program
    }

    /// The override outlives the session because it is persisted by strip and read back by strip — and the engine is
    /// seeded with it on the next load, so playback actually uses it.
    @Test func `a program override survives an app relaunch`() async {
        let item = Self.makeItem()
        // One repository stands in for the on-disk store across both "launches".
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
                Part(
                    id: "P1", trackName: "Pno",
                    instrument: Instrument(id: "p", channels: [InstrumentChannel(program: 0)]),
                    staves: [Staff(), Staff()],
                ),
            ],
            metaTags: [:],
        )
        let strips = [
            Self.strip(Self.violinStrip, name: "Vn", program: 40),
            Self.strip(Self.pianoStrip, name: "Pno", program: 0),
        ]

        // Session 1: choose Harpsichord (program 6) for the piano strip.
        let controller1 = FakePlaybackController()
        controller1.strips = strips
        let vm1 = ReaderViewModel(
            scoreItem: item, repository: repo, gateway: Self.makeGateway(score: score),
            scoresDirectory: URL(filePath: "/tmp"),
            playbackController: controller1,
        )
        await vm1.load()
        await vm1.playbackSession.prepareForPlayback()
        await vm1.mixerModel.setProgram(6, for: Self.pianoStrip)

        // The choice was written through to persistence.
        #expect(repo.storedReaderPreferences[item.id]?.stripProgramOverrides[Self.pianoStrip] == 6)

        // Session 2 (app relaunch): a brand-new view model + mixer over the same store.
        let controller2 = FakePlaybackController()
        controller2.strips = strips
        let vm2 = ReaderViewModel(
            scoreItem: item, repository: repo, gateway: Self.makeGateway(score: score),
            scoresDirectory: URL(filePath: "/tmp"),
            playbackController: controller2,
        )
        await vm2.load()
        await vm2.playbackSession.prepareForPlayback()

        // The mixer shows the override again — and only on the strip that carries it.
        #expect(vm2.mixerModel.effectiveProgram(for: Self.pianoStrip) == 6)
        #expect(vm2.mixerModel.hasProgramOverride(for: Self.pianoStrip))
        #expect(vm2.mixerModel.effectiveProgram(for: Self.violinStrip) == 40)

        // …and the engine was seeded with it on load.
        let seeded = controller2.lastLoadedPreferences?.perStrip ?? []
        #expect(seeded.first { $0.strip == Self.pianoStrip }?.gmProgram == 6)
        #expect(!seeded.contains { $0.strip == Self.violinStrip })
    }

    @Test func `initial playback preferences carry only the saved overrides`() async throws {
        let item = Self.makeItem()
        let repo = FakeScoreLibraryRepository()
        repo.scoreItems = [item]
        repo.storedReaderPreferences[item.id] = ReaderPreferences(
            scoreItemID: item.id, staffSize: 14, hiddenStaves: [],
            stripProgramOverrides: [Self.pianoStrip: 24], // Acoustic Guitar
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
        await vm.playbackSession.togglePlayback()

        let prefs = try #require(controller.lastLoadedPreferences)
        // The violin has no override, so nothing is sent for it — the engine's own seeding from the score stands.
        #expect(prefs.perStrip.map(\.strip) == [Self.pianoStrip])
        #expect(prefs.perStrip.first?.gmProgram == 24)
    }

    @Test func `set volume forwards to controller by strip`() async {
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

        vm.mixerModel.setVolume(0.3, for: Self.pianoStrip)
        await Task.yield()
        await Task.yield()
        #expect(controller.stripVolumes.map(\.strip) == [Self.pianoStrip])
        #expect(controller.stripVolumes.map(\.volume) == [0.3])
    }

    @Test func `engine seed uses persisted override over mscx`() async throws {
        let item = Self.makeItem()
        let repo = FakeScoreLibraryRepository()
        repo.scoreItems = [item]
        repo.storedReaderPreferences[item.id] = ReaderPreferences(
            scoreItemID: item.id,
            staffSize: 14,
            hiddenStaves: [],
            stripVolumeOverrides: [Self.violinStrip: 0.3],
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
        await vm.playbackSession.prepareForPlayback()

        let seeded = try #require(controller.lastLoadedPreferences)
        let violin = try #require(seeded.perStrip.first { $0.strip == Self.violinStrip })
        #expect(violin.volume == 0.3)
    }

    /// With nothing overridden there is nothing to seed: the engine already applied the score's own CC 7 when it
    /// prepared, and re-sending it would only risk contradicting what the score authored.
    @Test func `engine seed is empty when nothing was overridden`() async throws {
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
        await vm.playbackSession.prepareForPlayback()

        let seeded = try #require(controller.lastLoadedPreferences)
        #expect(seeded.perStrip.isEmpty)
    }
}
