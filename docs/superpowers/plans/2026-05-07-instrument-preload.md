# Inspector Instrument Cache-Aware Preload — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the Reader Inspector's instrument-pick menu cache-aware: prefetch the soundfont before swapping the engine, mirror the score-open `loading / offline` alert flow when the user (or already-running playback) needs to wait, auto-resume playback after success, and revert the override on cancel.

**Architecture:** Add per-patch cache check + prefetch APIs to `Domain.PlaybackController` (thin adapters over the existing `domainResolver` in `LivePlaybackController`). Add a `pendingInstrumentLoad` state machine to `ReaderViewModel` that branches `setPartProgram` into cache-hit (current synchronous behavior) and cache-miss (snapshot → mutate → maybe-pause → prefetch → apply-or-revert) paths. Extend `togglePlayback` so that if a silent prefetch is in flight when the user taps Play, the existing alert appears and we wait. Cancel routes through the prefetch task's catch branch and reverts overrides per-staff.

**Tech Stack:** Swift 6.3, Swift Testing (`@Test` / `#expect`), iOS 26+, SPM module layout (`Domain` ← `Infrastructure` ← `Reader` feature), existing `FakePlaybackController` / `FakeNetworkReachability` test doubles.

---

## File Structure

**Modify:**
- `Packages/Domain/Sources/Domain/Protocols/PlaybackController.swift` — declare two new methods.
- `Packages/Infrastructure/Sources/Audio/LivePlaybackController.swift` — implement them as thin adapters over `domainResolver`.
- `Packages/Features/Reader/Sources/Reader/ReaderViewModel.swift` — add `PendingInstrumentLoad`, restructure `setPartProgram`, branch in `togglePlayback`, extend `cancelLoadingSoundfonts`.
- `Packages/Features/Reader/Tests/ReaderTests/Fakes/FakePlaybackController.swift` — add cache + prefetch state.

**New tests:**
- New `@Test` cases in `Packages/Features/Reader/Tests/ReaderTests/ReaderViewModelPlaybackTests.swift` (9 cases).
- New `@Test` cases in `Packages/Infrastructure/Tests/InfrastructureTests/Audio/LivePlaybackControllerTests.swift` (2 cases) — needs a small `FakeDomainSoundfontResolver` test fixture; create alongside the test if no shared one exists.

**No changes to:** Inspector view, alert View binding (existing `cancelLoadingSoundfonts` hook handles both tasks once extended), localization strings (existing `.loading` / `.offline` copy is reused), score-open `prepareForPlayback`, `clearPartProgramOverride` (the path back to the score default is assumed to be cached because score-open already prefetched it).

---

## Task 1: Add the two new methods to the `PlaybackController` protocol

**Files:**
- Modify: `Packages/Domain/Sources/Domain/Protocols/PlaybackController.swift`

This task changes a public protocol; the project will not compile until every conformer (live + fake) has the methods. We add the protocol stubs and stop-gap conformances in the same task to keep `swift build` green between commits, then flesh out the live implementation in Task 2.

- [ ] **Step 1: Add the two new method requirements**

Open `Packages/Domain/Sources/Domain/Protocols/PlaybackController.swift`. Below the existing `areSoundfontsAvailableLocally(for:)` declaration (around line 16), append:

```swift
    /// True iff the soundfont for `(bank, program, isDrums)` is already
    /// on disk (bundled or cached). Mirrors
    /// `areSoundfontsAvailableLocally(for:)` at per-patch granularity —
    /// the Inspector instrument-pick path uses this to decide whether
    /// `setStaffInstrument` would fall back to a bundled patch.
    func isSoundfontCached(bank: Int, program: Int, isDrums: Bool) async -> Bool

    /// Download and cache a single patch. Resolves on success; throws
    /// `CancellationError` on `Task.cancel()`, or rethrows resolver
    /// failures. Idempotent — a no-op if the patch is already cached.
    func prefetchSoundfont(bank: Int, program: Int, isDrums: Bool) async throws
```

- [ ] **Step 2: Add stop-gap implementations to `LivePlaybackController` so the project still compiles**

Open `Packages/Infrastructure/Sources/Audio/LivePlaybackController.swift`. Find `areSoundfontsAvailableLocally(for:)` around line 124. Below its closing `}`, insert:

```swift
    public func isSoundfontCached(bank: Int, program: Int, isDrums: Bool) async -> Bool {
        fatalError("Implemented in Task 2")
    }

    public func prefetchSoundfont(bank: Int, program: Int, isDrums: Bool) async throws {
        fatalError("Implemented in Task 2")
    }
```

(These will be replaced wholesale in Task 2; `fatalError` is acceptable as a one-commit stop-gap because no test or runtime path hits them yet.)

- [ ] **Step 3: Add stop-gap implementations to `FakePlaybackController` so `Reader` tests still compile**

Open `Packages/Features/Reader/Tests/ReaderTests/Fakes/FakePlaybackController.swift`. Below `areSoundfontsAvailableLocally(for:)` around line 50, insert:

```swift
    func isSoundfontCached(bank _: Int, program _: Int, isDrums _: Bool) -> Bool {
        true
    }

    func prefetchSoundfont(bank _: Int, program _: Int, isDrums _: Bool) async throws {}
```

The default fake returns `true` (cached) and the prefetch resolves immediately. Task 5 replaces these with the real recording fakes. Returning `true` here is deliberate: every existing `ReaderViewModelPartProgramTests` and `ReaderViewModelPlaybackTests` case was written before the cache-aware path existed, so they need the cache-hit behavior to keep their assertions intact across this and the next two tasks.

- [ ] **Step 4: Build the SPM packages to confirm everything still compiles**

Run:

```sh
cd Packages/Domain && swift build && cd -
cd Packages/Infrastructure && swift build && cd -
cd Packages/Features/Reader && swift build && cd -
```

Expected: each `swift build` succeeds with no errors.

- [ ] **Step 5: Run the existing test suites to confirm nothing regressed**

Run:

```sh
cd Packages/Features/Reader && swift test && cd -
cd Packages/Infrastructure && swift test && cd -
```

Expected: all existing tests pass (the new methods aren't exercised yet).

- [ ] **Step 6: Commit**

```sh
git add Packages/Domain/Sources/Domain/Protocols/PlaybackController.swift \
        Packages/Infrastructure/Sources/Audio/LivePlaybackController.swift \
        Packages/Features/Reader/Tests/ReaderTests/Fakes/FakePlaybackController.swift
git commit -m "$(cat <<'EOF'
feat(playback): declare per-patch cache and prefetch on PlaybackController

Adds isSoundfontCached and prefetchSoundfont to the protocol with
stop-gap conformances on LivePlaybackController (fatalError, replaced
in the next commit) and FakePlaybackController (cache-hit defaults so
existing Reader tests keep their behaviour).
EOF
)"
```

---

## Task 2: Implement the live methods on `LivePlaybackController` (TDD)

**Files:**
- Test: `Packages/Infrastructure/Tests/InfrastructureTests/Audio/LivePlaybackControllerTests.swift`
- Modify: `Packages/Infrastructure/Sources/Audio/LivePlaybackController.swift`

The two methods are thin adapters over the existing `domainResolver`. We test them via a hand-rolled in-test `FakeDomainSoundfontResolver` so the test stays in `InfrastructureTests` and doesn't reach for network or disk.

- [ ] **Step 1: Write the failing tests**

Open `Packages/Infrastructure/Tests/InfrastructureTests/Audio/LivePlaybackControllerTests.swift`. Above the closing `}` of the `@Suite` (before `// MARK: - Fixtures`), append:

```swift
    @Test func isSoundfontCachedReturnsTrueWhenResolverListsPatch() async {
        let resolver = FakeDomainSoundfontResolver(cached: [
            SoundfontPatchKey(bank: 0, program: 73, isDrums: false),
        ])
        let controller = LivePlaybackController(
            soundfontResolver: NoopAudioResolver(),
            domainResolver: resolver,
            precisionProbe: StubProbe(available: [])
        )

        let cached = await controller.isSoundfontCached(bank: 0, program: 73, isDrums: false)
        let missing = await controller.isSoundfontCached(bank: 8, program: 0, isDrums: false)
        #expect(cached)
        #expect(!missing)
    }

    @Test func isSoundfontCachedReturnsFalseWhenResolverThrows() async {
        let resolver = FakeDomainSoundfontResolver(cachedPatchesError: TestError.boom)
        let controller = LivePlaybackController(
            soundfontResolver: NoopAudioResolver(),
            domainResolver: resolver,
            precisionProbe: StubProbe(available: [])
        )

        let result = await controller.isSoundfontCached(bank: 0, program: 0, isDrums: false)
        #expect(!result)
    }

    @Test func prefetchSoundfontDelegatesToResolver() async throws {
        let resolver = FakeDomainSoundfontResolver()
        let controller = LivePlaybackController(
            soundfontResolver: NoopAudioResolver(),
            domainResolver: resolver,
            precisionProbe: StubProbe(available: [])
        )

        try await controller.prefetchSoundfont(bank: 8, program: 0, isDrums: false)
        let calls = await resolver.resolveCalls
        #expect(calls.count == 1)
        #expect(calls.first?.bank == 8)
        #expect(calls.first?.program == 0)
        #expect(calls.first?.isDrums == false)
    }

    @Test func prefetchSoundfontPropagatesResolverError() async {
        let resolver = FakeDomainSoundfontResolver(resolveError: TestError.boom)
        let controller = LivePlaybackController(
            soundfontResolver: NoopAudioResolver(),
            domainResolver: resolver,
            precisionProbe: StubProbe(available: [])
        )

        await #expect(throws: TestError.boom) {
            try await controller.prefetchSoundfont(bank: 0, program: 0, isDrums: false)
        }
    }
```

Then below the file's existing `// MARK: - Fixtures` block (after `firstChannel`), append:

```swift
private enum TestError: Error, Equatable { case boom }

/// Minimal AudioResolver — required by `LivePlaybackController.init` but
/// never consulted by the cache / prefetch paths under test, which only
/// touch the Domain resolver.
private struct NoopAudioResolver: SheetMusicAudio.SoundfontResolver {
    func soundfontURL(forBank _: UInt8, program _: UInt8, isDrums _: Bool) -> URL? {
        nil
    }

    var defaultGMSoundfontURL: URL? { nil }
}

/// Records `resolveSoundfont` calls and returns either a fake URL or the
/// configured error. `cachedPatches()` returns one `SoundfontPatch` per
/// key in `cached`, or throws `cachedPatchesError` if set.
private actor FakeDomainSoundfontResolver: Domain.SoundfontResolver {
    var cached: Set<SoundfontPatchKey>
    var cachedPatchesError: Error?
    var resolveError: Error?
    private(set) var resolveCalls: [(bank: Int, program: Int, isDrums: Bool)] = []

    init(
        cached: Set<SoundfontPatchKey> = [],
        cachedPatchesError: Error? = nil,
        resolveError: Error? = nil
    ) {
        self.cached = cached
        self.cachedPatchesError = cachedPatchesError
        self.resolveError = resolveError
    }

    func resolveSoundfont(bank: Int, program: Int, isDrums: Bool) async throws -> URL {
        resolveCalls.append((bank, program, isDrums))
        if let error = resolveError { throw error }
        cached.insert(SoundfontPatchKey(bank: bank, program: program, isDrums: isDrums))
        return URL(fileURLWithPath: "/tmp/sf-\(bank)-\(program)-\(isDrums).sf2")
    }

    func cachedPatches() async throws -> [SoundfontPatch] {
        if let error = cachedPatchesError { throw error }
        let now = Date(timeIntervalSince1970: 0)
        return cached.map {
            SoundfontPatch(
                bank: $0.bank, program: $0.program,
                localFileName: "fake.sf2", sizeBytes: 0,
                downloadedAt: now, lastUsedAt: now,
                isBundled: false, isDrums: $0.isDrums
            )
        }
    }

    func totalCacheSizeBytes() async throws -> Int64 { 0 }
    func deletePatch(bank _: Int, program _: Int, isDrums _: Bool) async throws {}
    func clearCache() async throws {}
}
```

The file already has `import Domain`; if it does not also `import SheetMusicAudio`, add it at the top — `NoopAudioResolver` and `LivePlaybackController.init` need it. Check the existing imports first; only add what's missing.

- [ ] **Step 2: Run the new tests to confirm they fail**

Run:

```sh
cd Packages/Infrastructure && swift test --filter LivePlaybackControllerTests && cd -
```

Expected: the four new tests fail with `Fatal error: Implemented in Task 2`.

- [ ] **Step 3: Replace the stop-gap implementations with the real ones**

Open `Packages/Infrastructure/Sources/Audio/LivePlaybackController.swift`. Replace the two `fatalError` methods inserted in Task 1 with:

```swift
    public func isSoundfontCached(bank: Int, program: Int, isDrums: Bool) async -> Bool {
        do {
            let patches = try await domainResolver.cachedPatches()
            let needle = SoundfontPatchKey(bank: bank, program: program, isDrums: isDrums)
            return patches.contains { patch in
                SoundfontPatchKey(bank: patch.bank, program: patch.program, isDrums: patch.isDrums) == needle
            }
        } catch {
            // Match `areSoundfontsAvailableLocally`'s policy: if the cache
            // can't be enumerated, report "not cached" so callers surface
            // the loading affordance instead of stalling silently.
            return false
        }
    }

    public func prefetchSoundfont(bank: Int, program: Int, isDrums: Bool) async throws {
        _ = try await domainResolver.resolveSoundfont(
            bank: bank, program: program, isDrums: isDrums
        )
    }
```

- [ ] **Step 4: Run the tests to confirm they pass**

Run:

```sh
cd Packages/Infrastructure && swift test --filter LivePlaybackControllerTests && cd -
```

Expected: all `LivePlaybackControllerTests` cases pass.

- [ ] **Step 5: Commit**

```sh
git add Packages/Infrastructure/Sources/Audio/LivePlaybackController.swift \
        Packages/Infrastructure/Tests/InfrastructureTests/Audio/LivePlaybackControllerTests.swift
git commit -m "$(cat <<'EOF'
feat(playback): adapt isSoundfontCached and prefetchSoundfont to domain resolver

Per-patch cache check and prefetch on LivePlaybackController, both thin
wrappers over the existing Domain.SoundfontResolver. Cache check matches
areSoundfontsAvailableLocally's swallow-and-return-false on enumeration
failure so callers surface the loading affordance.
EOF
)"
```

---

## Task 3: Beef up `FakePlaybackController` with cache + prefetch state

**Files:**
- Modify: `Packages/Features/Reader/Tests/ReaderTests/Fakes/FakePlaybackController.swift`

The Task 1 stop-gap returned `true` for everything. Tasks 4–10 need a fake that records prefetch calls, blocks on demand, and lets each test choose what's cached.

- [ ] **Step 1: Replace the stop-gap methods and add the new state**

Open `Packages/Features/Reader/Tests/ReaderTests/Fakes/FakePlaybackController.swift`. Find the two stop-gap methods inserted in Task 1:

```swift
    func isSoundfontCached(bank _: Int, program _: Int, isDrums _: Bool) -> Bool {
        true
    }

    func prefetchSoundfont(bank _: Int, program _: Int, isDrums _: Bool) async throws {}
```

Replace them with:

```swift
    /// Patches the fake reports as already on disk. Default: empty —
    /// every pick is a cache miss unless the test seeds this set.
    var cachedPatches: Set<SoundfontPatchKey> = []
    private(set) var prefetchedPatches: [SoundfontPatchKey] = []
    /// When true, `prefetchSoundfont` suspends until `Task.cancel()`
    /// fires, throwing `CancellationError`. Mirrors
    /// `blocksLoadUntilCancelled` for the per-patch path.
    var blocksPrefetchUntilCancelled: Bool = false
    var prefetchError: Error?

    func isSoundfontCached(bank: Int, program: Int, isDrums: Bool) -> Bool {
        cachedPatches.contains(SoundfontPatchKey(bank: bank, program: program, isDrums: isDrums))
    }

    func prefetchSoundfont(bank: Int, program: Int, isDrums: Bool) async throws {
        if blocksPrefetchUntilCancelled {
            try await Task.sleep(for: .seconds(60))
        }
        if let error = prefetchError { throw error }
        let key = SoundfontPatchKey(bank: bank, program: program, isDrums: isDrums)
        prefetchedPatches.append(key)
        cachedPatches.insert(key)
    }
```

Note the default `cachedPatches = []` flips the fake's behaviour from "always cached" (Task 1 stop-gap) to "never cached unless seeded". This is intentional — Task 4 widens `setPartProgram` to take the cache-miss branch, and existing tests in `ReaderViewModelPartProgramTests` will go through the cache-miss path silently (no `wasPlaying`, no alert) and still see the same end-state because the new path also calls `setStaffInstrument` after the (immediate, in-process) prefetch resolves.

- [ ] **Step 2: Run the existing Reader test suite to confirm the wider miss path is benign**

Run:

```sh
cd Packages/Features/Reader && swift test && cd -
```

Expected: all existing `ReaderViewModelPlaybackTests` and `ReaderViewModelPartProgramTests` pass (their assertions about preferences + `staffInstrumentCalls` still hold because the cache-miss path also fans out `setStaffInstrument` after the prefetch resolves).

If a test fails because it checks `staffInstrumentCalls.count` exactly and the new path adds an ordering wrinkle, fix the test to filter by program/staff (matching the existing `setPartProgramAppliesOverrideToEveryStaffUnderThePart` style) rather than relying on a brittle count.

- [ ] **Step 3: Commit**

```sh
git add Packages/Features/Reader/Tests/ReaderTests/Fakes/FakePlaybackController.swift
git commit -m "$(cat <<'EOF'
test(reader): teach FakePlaybackController about per-patch cache and prefetch

Replaces the Task-1 stop-gap with cachedPatches / prefetchedPatches /
blocksPrefetchUntilCancelled, defaulting to "never cached" so upcoming
cache-miss tests don't have to opt in. Existing tests still pass — the
new setPartProgram cache-miss path produces the same end-state.
EOF
)"
```

---

## Task 4: Add the cache-miss branch to `setPartProgram` (TDD — silent prefetch path)

**Files:**
- Test: `Packages/Features/Reader/Tests/ReaderTests/ReaderViewModelPlaybackTests.swift`
- Modify: `Packages/Features/Reader/Sources/Reader/ReaderViewModel.swift`

We grow `setPartProgram` in three slices: silent (Task 4), playing (Task 5), with cancellation + secondary picks (Task 6). Each slice is one or two tests + the matching code change, ending in green.

- [ ] **Step 1: Write the failing tests for the silent path**

Open `Packages/Features/Reader/Tests/ReaderTests/ReaderViewModelPlaybackTests.swift`. Above the final closing `}`, append:

```swift
    @Test func setPartProgramWithCachedPatchSkipsPrefetch() async {
        let item = Self.makeItem()
        let repo = FakeScoreLibraryRepository()
        repo.scoreItems = [item]
        let score = Score(
            division: 480,
            parts: [Part(
                id: "P0", trackName: "Vn",
                instrument: Instrument(id: "v", channels: [InstrumentChannel(program: 40)]),
                staves: [Staff()]
            )],
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
            parts: [Part(
                id: "P0", trackName: "Vn",
                instrument: Instrument(id: "v", channels: [InstrumentChannel(program: 40)]),
                staves: [Staff()]
            )],
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
```

- [ ] **Step 2: Run the new tests to confirm they fail**

Run:

```sh
cd Packages/Features/Reader && swift test --filter ReaderViewModelPlaybackTests && cd -
```

Expected: `setPartProgramWithUncachedPatchPrefetchesSilentlyWhenNotPlaying` fails because `controller.prefetchedPatches` is empty (current `setPartProgram` doesn't call prefetch). `setPartProgramWithCachedPatchSkipsPrefetch` may already pass — that's fine, it locks in the cache-hit short-circuit.

- [ ] **Step 3: Add `PendingInstrumentLoad` and the per-staff snapshot helper**

Open `Packages/Features/Reader/Sources/Reader/ReaderViewModel.swift`. Below the existing `@ObservationIgnored private var preloadTask: Task<Void, Error>?` declaration (around line 70), insert:

```swift
    @ObservationIgnored
    private var pendingInstrumentLoad: PendingInstrumentLoad?

    private struct PendingInstrumentLoad {
        let partIndex: Int
        let bank: Int
        let program: Int
        let isDrums: Bool
        /// Per-staff snapshot of the override map restricted to this part
        /// at the moment the pick was registered. `nil` value means "no
        /// override existed for that address; remove on revert".
        let previousOverrides: [(address: StaffAddress, previous: Int?)]
        /// True iff playback was running at the moment we registered the
        /// pick (or was inherited from an earlier in-flight pick that we
        /// just cancelled). Drives auto-resume on success.
        let wasPlaying: Bool
        let task: Task<Void, Error>
    }
```

- [ ] **Step 4: Restructure `setPartProgram` to take the cache-miss branch (silent flavour only — playing branch and cancel revert come in Tasks 5 and 6)**

In the same file, replace the entire `public func setPartProgram(_:forPartIndex:)` body (around line 507 in the file extension) with:

```swift
    public func setPartProgram(_ program: Int, forPartIndex partIndex: Int) async {
        let addresses = partStaffAddresses(forPartIndex: partIndex)
        guard !addresses.isEmpty,
              case let .loaded(score) = loadState,
              score.parts.indices.contains(partIndex)
        else { return }
        let part = score.parts[partIndex]
        let bank = part.instrument.channel.bank
        let isDrums = part.instrument.useDrumset

        if let controller = playbackController,
           await controller.isSoundfontCached(
               bank: bank, program: program, isDrums: isDrums
           ) == false
        {
            await runUncachedPartProgramSwap(
                program: program, partIndex: partIndex,
                addresses: addresses, bank: bank, isDrums: isDrums,
                controller: controller
            )
            return
        }

        // Cache-hit (or no controller): preserve the original synchronous
        // behaviour — persist the override and fan out to the engine.
        await mutatePreferences { prefs in
            for address in addresses {
                prefs.staffProgramOverrides[address] = program
            }
        }
        for address in addresses {
            guard let flatIndex = flattenedStaffIndex(for: address) else { continue }
            await playbackController?.setStaffInstrument(
                staff: flatIndex,
                bank: scoreDefaultBank(for: address) ?? 0,
                program: program
            )
        }
    }

    private func runUncachedPartProgramSwap(
        program: Int,
        partIndex: Int,
        addresses: [StaffAddress],
        bank: Int,
        isDrums: Bool,
        controller: any PlaybackController
    ) async {
        let snapshot = addresses.map { address in
            (address: address, previous: preferences.staffProgramOverrides[address])
        }
        await mutatePreferences { prefs in
            for address in addresses {
                prefs.staffProgramOverrides[address] = program
            }
        }

        let task = Task<Void, Error> {
            try await controller.prefetchSoundfont(
                bank: bank, program: program, isDrums: isDrums
            )
        }
        let pending = PendingInstrumentLoad(
            partIndex: partIndex, bank: bank, program: program, isDrums: isDrums,
            previousOverrides: snapshot, wasPlaying: false, task: task
        )
        pendingInstrumentLoad = pending

        do {
            try await task.value
            for address in addresses {
                guard let flatIndex = flattenedStaffIndex(for: address) else { continue }
                await controller.setStaffInstrument(
                    staff: flatIndex, bank: bank, program: program
                )
            }
        } catch {
            // Cancel / failure: revert per-staff overrides.
            await mutatePreferences { prefs in
                for entry in snapshot {
                    if let previous = entry.previous {
                        prefs.staffProgramOverrides[entry.address] = previous
                    } else {
                        prefs.staffProgramOverrides.removeValue(forKey: entry.address)
                    }
                }
            }
        }
        pendingInstrumentLoad = nil
    }
```

- [ ] **Step 5: Run the tests to confirm they pass**

Run:

```sh
cd Packages/Features/Reader && swift test --filter ReaderViewModelPlaybackTests && cd -
```

Expected: both new tests plus all existing tests in the suite pass.

- [ ] **Step 6: Commit**

```sh
git add Packages/Features/Reader/Sources/Reader/ReaderViewModel.swift \
        Packages/Features/Reader/Tests/ReaderTests/ReaderViewModelPlaybackTests.swift
git commit -m "$(cat <<'EOF'
feat(reader): silently prefetch on cache-miss when picking an instrument

Splits setPartProgram into a cache-hit fast path (current behaviour) and
a cache-miss path that snapshots per-staff overrides, mutates preferences
to the new pick, awaits the prefetch, then fans setStaffInstrument out to
each staff. Failure or cancellation reverts the snapshot. Playing-branch
and togglePlayback wait come in the next two commits.
EOF
)"
```

---

## Task 5: Pause and alert when picking a cache-miss instrument during playback (TDD)

**Files:**
- Test: `Packages/Features/Reader/Tests/ReaderTests/ReaderViewModelPlaybackTests.swift`
- Modify: `Packages/Features/Reader/Sources/Reader/ReaderViewModel.swift`

Adds the `wasPlaying` branch and the auto-resume on success.

- [ ] **Step 1: Write the failing tests**

Append to `Packages/Features/Reader/Tests/ReaderTests/ReaderViewModelPlaybackTests.swift`:

```swift
    @Test func setPartProgramDuringPlaybackPausesAndShowsLoadingAlert() async {
        let item = Self.makeItem()
        let repo = FakeScoreLibraryRepository()
        repo.scoreItems = [item]
        let score = Score(
            division: 480,
            parts: [Part(
                id: "P0", trackName: "Vn",
                instrument: Instrument(id: "v", channels: [InstrumentChannel(program: 40)]),
                staves: [Staff()]
            )],
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
        // Get into the "playing" state via the existing toggle path —
        // soundfontsAvailableLocally is irrelevant here because togglePlayback's
        // alert path looks at the score-level cache, which we satisfy with the
        // single seeded patch above.
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
            parts: [Part(
                id: "P0", trackName: "Vn",
                instrument: Instrument(id: "v", channels: [InstrumentChannel(program: 40)]),
                staves: [Staff()]
            )],
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
        #expect(controller.playCount == playsBefore + 1) // one resume
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
            parts: [Part(
                id: "P0", trackName: "Vn",
                instrument: Instrument(id: "v", channels: [InstrumentChannel(program: 40)]),
                staves: [Staff()]
            )],
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
```

- [ ] **Step 2: Run the new tests to confirm they fail**

Run:

```sh
cd Packages/Features/Reader && swift test --filter ReaderViewModelPlaybackTests && cd -
```

Expected: all three new tests fail (current code never sets `soundfontAlertKind`, never calls `pause`, and never auto-resumes).

- [ ] **Step 3: Extend `runUncachedPartProgramSwap` with the playing branch**

Open `Packages/Features/Reader/Sources/Reader/ReaderViewModel.swift`. Replace `runUncachedPartProgramSwap` (the helper added in Task 4) with:

```swift
    private func runUncachedPartProgramSwap(
        program: Int,
        partIndex: Int,
        addresses: [StaffAddress],
        bank: Int,
        isDrums: Bool,
        controller: any PlaybackController
    ) async {
        let snapshot = addresses.map { address in
            (address: address, previous: preferences.staffProgramOverrides[address])
        }
        await mutatePreferences { prefs in
            for address in addresses {
                prefs.staffProgramOverrides[address] = program
            }
        }

        let wasPlaying = isPlaying
        if isPlaying {
            await controller.pause()
            isPlaying = false
        }
        if wasPlaying {
            let online = await reachability?.isOnline() ?? true
            soundfontAlertKind = online ? .loading : .offline
        }

        let task = Task<Void, Error> {
            try await controller.prefetchSoundfont(
                bank: bank, program: program, isDrums: isDrums
            )
        }
        let pending = PendingInstrumentLoad(
            partIndex: partIndex, bank: bank, program: program, isDrums: isDrums,
            previousOverrides: snapshot, wasPlaying: wasPlaying, task: task
        )
        pendingInstrumentLoad = pending

        do {
            try await task.value
            for address in addresses {
                guard let flatIndex = flattenedStaffIndex(for: address) else { continue }
                await controller.setStaffInstrument(
                    staff: flatIndex, bank: bank, program: program
                )
            }
            soundfontAlertKind = nil
            if wasPlaying {
                do {
                    try await controller.play()
                    isPlaying = true
                } catch {
                    isPlaying = false
                }
            }
        } catch {
            await mutatePreferences { prefs in
                for entry in snapshot {
                    if let previous = entry.previous {
                        prefs.staffProgramOverrides[entry.address] = previous
                    } else {
                        prefs.staffProgramOverrides.removeValue(forKey: entry.address)
                    }
                }
            }
            soundfontAlertKind = nil
            // Q1 A: only auto-resume on success. Cancel leaves us paused.
        }
        pendingInstrumentLoad = nil
    }
```

- [ ] **Step 4: Extend `cancelLoadingSoundfonts` to cancel the instrument prefetch too**

In the same file, find `cancelLoadingSoundfonts` (around line 321). Replace with:

```swift
    public func cancelLoadingSoundfonts() {
        preloadTask?.cancel()
        pendingInstrumentLoad?.task.cancel()
    }
```

- [ ] **Step 5: Run the tests to confirm they pass**

Run:

```sh
cd Packages/Features/Reader && swift test --filter ReaderViewModelPlaybackTests && cd -
```

Expected: all three new tests pass alongside the previously green ones.

- [ ] **Step 6: Commit**

```sh
git add Packages/Features/Reader/Sources/Reader/ReaderViewModel.swift \
        Packages/Features/Reader/Tests/ReaderTests/ReaderViewModelPlaybackTests.swift
git commit -m "$(cat <<'EOF'
feat(reader): pause and alert when changing instruments during playback

When the Inspector pick is a cache miss and playback is running, pause
the engine, surface the loading/offline alert, await the prefetch, push
to the engine, and resume on success. Cancel reverts the override and
leaves playback paused (per Q1 A: only success auto-resumes).
EOF
)"
```

---

## Task 6: Cancel + secondary-pick semantics — explicit tests for revert and `wasPlaying` inheritance

**Files:**
- Test: `Packages/Features/Reader/Tests/ReaderTests/ReaderViewModelPlaybackTests.swift`
- Modify: `Packages/Features/Reader/Sources/Reader/ReaderViewModel.swift`

Tasks 4 and 5 already revert on cancel. This task adds focused regression tests for both Q2 A (cancel reverts) and Q3 (latest pick wins, `wasPlaying` inherited from the cancelled pick), plus the small piece of code that performs the inheritance.

- [ ] **Step 1: Write the failing tests**

Append to `Packages/Features/Reader/Tests/ReaderTests/ReaderViewModelPlaybackTests.swift`:

```swift
    @Test func cancelDuringInstrumentPrefetchRevertsProgramOverride() async {
        let item = Self.makeItem()
        let repo = FakeScoreLibraryRepository()
        repo.scoreItems = [item]
        let score = Score(
            division: 480,
            parts: [Part(
                id: "P0", trackName: "Vn",
                instrument: Instrument(id: "v", channels: [InstrumentChannel(program: 40)]),
                staves: [Staff()]
            )],
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
        // Mid-flight: preferences reflect the new pick.
        #expect(vm.preferences.staffProgramOverrides[address] == 6)

        vm.cancelLoadingSoundfonts()
        _ = await pick.value

        // Cancel reverted the override (no entry → score default).
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
            parts: [Part(
                id: "P0", trackName: "Vn",
                instrument: Instrument(id: "v", channels: [InstrumentChannel(program: 40)]),
                staves: [Staff()]
            )],
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

        // First pick (6 = Harpsichord) — cache miss, blocks.
        let firstPick = Task { await vm.setPartProgram(6, forPartIndex: 0) }
        for _ in 0 ..< 5 { await Task.yield() }

        // Second pick (24 = Acoustic Guitar) — should cancel the first.
        let secondPick = Task { await vm.setPartProgram(24, forPartIndex: 0) }
        for _ in 0 ..< 10 { await Task.yield() }
        _ = await firstPick.value

        // Cancel the second one; revert should land on the original (40),
        // not on 6 (which the first pick had already mutated).
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
            parts: [Part(
                id: "P0", trackName: "Vn",
                instrument: Instrument(id: "v", channels: [InstrumentChannel(program: 40)]),
                staves: [Staff()]
            )],
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

        // First pick blocks — VM pauses, sets alert.
        controller.blocksPrefetchUntilCancelled = true
        let firstPick = Task { await vm.setPartProgram(6, forPartIndex: 0) }
        for _ in 0 ..< 5 { await Task.yield() }
        #expect(!vm.isPlaying)
        #expect(vm.soundfontAlertKind == .loading)

        // Second pick — first one should be cancelled, second inherits wasPlaying.
        // Allow the second pick to complete by clearing the block.
        controller.blocksPrefetchUntilCancelled = false
        let secondPick = Task { await vm.setPartProgram(24, forPartIndex: 0) }
        _ = await firstPick.value
        _ = await secondPick.value

        // Q3 / Q1 A combined: even though isPlaying was false at the moment
        // we registered the second pick, wasPlaying was inherited and we
        // auto-resumed on success.
        #expect(vm.isPlaying)
        let calls = controller.staffInstrumentCalls.filter { $0.program == 24 }
        #expect(calls.count == 1)
    }
```

- [ ] **Step 2: Run the new tests to confirm the inheritance test fails**

Run:

```sh
cd Packages/Features/Reader && swift test --filter ReaderViewModelPlaybackTests && cd -
```

Expected: `cancelDuringInstrumentPrefetchRevertsProgramOverride` and `secondInstrumentPickCancelsFirstAndKeepsOriginalAsRevertTarget` likely already pass (the cancel + revert works from Tasks 4–5). `secondInstrumentPickInheritsWasPlayingFromFirstPick` fails — the second pick sees `isPlaying == false` and never resumes.

- [ ] **Step 3: Replace `runUncachedPartProgramSwap` with the in-flight cancellation + `wasPlaying` inheritance variant**

Open `Packages/Features/Reader/Sources/Reader/ReaderViewModel.swift`. Replace the entire `runUncachedPartProgramSwap` body (added in Task 4, extended in Task 5) with this final version:

```swift
    private func runUncachedPartProgramSwap(
        program: Int,
        partIndex: Int,
        addresses: [StaffAddress],
        bank: Int,
        isDrums: Bool,
        controller: any PlaybackController
    ) async {
        // 1. Latest pick wins on the same part: cancel any in-flight pick
        //    and inherit its wasPlaying — without inheritance the new pick
        //    would never auto-resume because the previous one already
        //    paused us.
        var inheritedWasPlaying = false
        if let existing = pendingInstrumentLoad, existing.partIndex == partIndex {
            inheritedWasPlaying = existing.wasPlaying
            existing.task.cancel()
            // Block until the cancelled task's catch branch finishes its
            // revert; otherwise our snapshot below captures the mid-flight
            // state the previous pick mutated to.
            _ = try? await existing.task.value
        }

        // 2. Decide pause / wasPlaying *before* mutating, but the snapshot
        //    is taken *after* any in-flight cancel above has reverted.
        let wasPlaying = isPlaying || inheritedWasPlaying
        if isPlaying {
            await controller.pause()
            isPlaying = false
        }

        let snapshot = addresses.map { address in
            (address: address, previous: preferences.staffProgramOverrides[address])
        }
        await mutatePreferences { prefs in
            for address in addresses {
                prefs.staffProgramOverrides[address] = program
            }
        }

        if wasPlaying {
            let online = await reachability?.isOnline() ?? true
            soundfontAlertKind = online ? .loading : .offline
        }

        let task = Task<Void, Error> {
            try await controller.prefetchSoundfont(
                bank: bank, program: program, isDrums: isDrums
            )
        }
        let pending = PendingInstrumentLoad(
            partIndex: partIndex, bank: bank, program: program, isDrums: isDrums,
            previousOverrides: snapshot, wasPlaying: wasPlaying, task: task
        )
        pendingInstrumentLoad = pending

        do {
            try await task.value
            for address in addresses {
                guard let flatIndex = flattenedStaffIndex(for: address) else { continue }
                await controller.setStaffInstrument(
                    staff: flatIndex, bank: bank, program: program
                )
            }
            soundfontAlertKind = nil
            if wasPlaying {
                do {
                    try await controller.play()
                    isPlaying = true
                } catch {
                    isPlaying = false
                }
            }
        } catch {
            await mutatePreferences { prefs in
                for entry in snapshot {
                    if let previous = entry.previous {
                        prefs.staffProgramOverrides[entry.address] = previous
                    } else {
                        prefs.staffProgramOverrides.removeValue(forKey: entry.address)
                    }
                }
            }
            soundfontAlertKind = nil
            // Q1 A: only success auto-resumes. Cancel leaves us paused.
        }
        pendingInstrumentLoad = nil
    }
```

- [ ] **Step 4: Run the tests to confirm they all pass**

Run:

```sh
cd Packages/Features/Reader && swift test --filter ReaderViewModelPlaybackTests && cd -
```

Expected: all three new tests plus the prior tests pass.

- [ ] **Step 5: Commit**

```sh
git add Packages/Features/Reader/Sources/Reader/ReaderViewModel.swift \
        Packages/Features/Reader/Tests/ReaderTests/ReaderViewModelPlaybackTests.swift
git commit -m "$(cat <<'EOF'
feat(reader): latest instrument pick wins, inherit wasPlaying

When the user picks a second instrument while the first prefetch is in
flight, cancel the first (its catch branch reverts) and inherit its
wasPlaying so the second pick still auto-resumes after success — even
though isPlaying is false at the moment we register the new pick.
EOF
)"
```

---

## Task 7: `togglePlayback` waits on a silent prefetch (TDD)

**Files:**
- Test: `Packages/Features/Reader/Tests/ReaderTests/ReaderViewModelPlaybackTests.swift`
- Modify: `Packages/Features/Reader/Sources/Reader/ReaderViewModel.swift`

If the user picked an instrument silently (not playing) and then taps Play before the prefetch finishes, `togglePlayback` must surface the alert and wait. After success, normal playback start runs (the `setPartProgram` task itself fans out `setStaffInstrument`).

- [ ] **Step 1: Write the failing tests**

Append to `Packages/Features/Reader/Tests/ReaderTests/ReaderViewModelPlaybackTests.swift`:

```swift
    @Test func togglePlaybackDuringSilentInstrumentPrefetchShowsLoadingAlert() async {
        let item = Self.makeItem()
        let repo = FakeScoreLibraryRepository()
        repo.scoreItems = [item]
        let score = Score(
            division: 480,
            parts: [Part(
                id: "P0", trackName: "Vn",
                instrument: Instrument(id: "v", channels: [InstrumentChannel(program: 40)]),
                staves: [Staff()]
            )],
            metaTags: [:]
        )
        let controller = FakePlaybackController()
        controller.soundfontsAvailableLocally = true   // engine prep is cheap
        controller.blocksPrefetchUntilCancelled = true
        let reachability = FakeNetworkReachability(online: true)
        let vm = ReaderViewModel(
            scoreItem: item, repository: repo, gateway: Self.makeGateway(score: score),
            scoresDirectory: URL(filePath: "/tmp"),
            playbackController: controller,
            reachability: reachability
        )
        await vm.load()

        // Silent prefetch starts, user is not playing.
        let pick = Task { await vm.setPartProgram(6, forPartIndex: 0) }
        for _ in 0 ..< 5 { await Task.yield() }
        #expect(vm.soundfontAlertKind == nil)

        // Now they tap Play — alert should appear.
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
            parts: [Part(
                id: "P0", trackName: "Vn",
                instrument: Instrument(id: "v", channels: [InstrumentChannel(program: 40)]),
                staves: [Staff()]
            )],
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

        // Pick already finished (prefetch resolved synchronously).
        await vm.togglePlayback()
        #expect(vm.isPlaying)
        #expect(controller.playCount == 1)
    }
```

- [ ] **Step 2: Run the new tests to confirm they fail**

Run:

```sh
cd Packages/Features/Reader && swift test --filter ReaderViewModelPlaybackTests && cd -
```

Expected: `togglePlaybackDuringSilentInstrumentPrefetchShowsLoadingAlert` fails (no alert appears). `togglePlaybackAfterSilentPrefetchSucceedsBeginsPlayback` likely passes already — that's fine, it locks the post-success path.

- [ ] **Step 3: Add the silent-prefetch wait branch to `togglePlayback`**

Open `Packages/Features/Reader/Sources/Reader/ReaderViewModel.swift`. Locate `togglePlayback` (around line 271). Just inside the function, **before** the `if !hasLoadedIntoPlayback {` block, insert:

```swift
        if let pending = pendingInstrumentLoad, !pending.wasPlaying {
            // Silent prefetch was kicked off when the user was not playing.
            // Surface the existing alert copy and wait. The prefetch task's
            // own success branch (in setPartProgram) fans setStaffInstrument
            // out; we just need to block until the engine reflects the
            // pick before kicking off play.
            let online = await reachability?.isOnline() ?? true
            soundfontAlertKind = online ? .loading : .offline
            do {
                try await pending.task.value
                soundfontAlertKind = nil
            } catch {
                soundfontAlertKind = nil
                return
            }
        }
```

Why this position: the existing `guard … soundfontAlertKind == nil else { return }` early-out means we set the alert *after* that check. Placing the wait branch before the engine-prep block keeps the order obvious — first wait for any pending instrument pick, then ensure the engine is loaded, then play.

- [ ] **Step 4: Run the tests to confirm they pass**

Run:

```sh
cd Packages/Features/Reader && swift test --filter ReaderViewModelPlaybackTests && cd -
```

Expected: both new tests plus all earlier tests pass.

- [ ] **Step 5: Commit**

```sh
git add Packages/Features/Reader/Sources/Reader/ReaderViewModel.swift \
        Packages/Features/Reader/Tests/ReaderTests/ReaderViewModelPlaybackTests.swift
git commit -m "$(cat <<'EOF'
feat(reader): show alert when Play taps a silent instrument prefetch

If the user picked a cache-miss instrument silently (not playing) and
then taps Play before the prefetch resolves, surface the existing
loading/offline alert and wait. The prefetch task's success branch
fans setStaffInstrument out, so togglePlayback just needs to block
before kicking off play.
EOF
)"
```

---

## Task 8: Wire the live `LivePlaybackController` into the App composition root

**Files:**
- Modify: search-and-confirm only — the App's composition root already constructs `LivePlaybackController`. No code change should be required because the new methods are protocol additions.

- [ ] **Step 1: Confirm the App still builds**

Run:

```sh
xcodegen generate
xcodebuild -project Folino.xcodeproj -scheme Folino \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -skipPackagePluginValidation build
```

Expected: BUILD SUCCEEDED. If it fails because some other conformer of `PlaybackController` exists (e.g. a preview-time fake in the App target), satisfy it the same way the test fakes were — return `true` from `isSoundfontCached` and resolve `prefetchSoundfont` immediately, with a one-line comment that it's a preview stub.

- [ ] **Step 2: If the build was already green, no commit. Otherwise:**

```sh
git add <touched files>
git commit -m "$(cat <<'EOF'
fix(app): satisfy new PlaybackController requirements in preview stubs
EOF
)"
```

---

## Task 9: Manual UI verification on the simulator

**Files:** none.

The previous tests cover the state machine. This step verifies that the alert actually appears in the Inspector flow and that the menu reflects the picked instrument before the prefetch resolves.

- [ ] **Step 1: Launch the app in the simulator and import a score whose default instrument is bundled (so the score-open prefetch is cheap), then open it in the Reader**

(Use any existing score in the Library; if none has a non-default instrument, import a small MusicXML / MSCX file with e.g. a violin part.)

- [ ] **Step 2: Wait for the score-open prefetch to settle, then pick an instrument from the Inspector menu that has not been used in any prior session — pick something exotic like Sitar (104) or Tinkle Bell (112)**

Expected (not playing): no alert, the Inspector menu label updates to the new instrument name, and after a few seconds the new patch is cached (you can verify by re-picking it; the second pick should be instant with no alert path even on tap Play).

- [ ] **Step 3: Pick another exotic uncached instrument, then immediately tap Play before the download finishes**

Expected: the "Loading playback sounds…" alert appears. Tapping Cancel reverts the pick (the menu label snaps back to the previous selection). Letting it finish dismisses the alert and starts playback.

- [ ] **Step 4: Tap Play to start playback, then while it's playing pick yet another exotic uncached instrument**

Expected: playback pauses immediately, the alert appears, and on success playback resumes with the new instrument audible.

- [ ] **Step 5: While the alert is up from step 4, tap Cancel**

Expected: the alert dismisses, the menu label reverts to the pre-pick instrument, playback stays paused. The user can tap Play to resume from the cursor position.

If any expectation fails, capture the discrepancy and stop — do not commit a "fix" without re-running the affected unit tests.

---

## Final Verification

- [ ] **Step 1: Run the full test suite (both packages affected)**

Run in parallel:

```sh
cd Packages/Features/Reader && swift test && cd -
cd Packages/Infrastructure && swift test && cd -
```

Expected: all tests pass.

- [ ] **Step 2: Confirm the app build is green**

```sh
xcodebuild -project Folino.xcodeproj -scheme Folino \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -skipPackagePluginValidation build
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Confirm `git log` shows the expected commit chain**

Run:

```sh
git log --oneline -10
```

Expected (most recent at top):

```
<sha> feat(reader): show alert when Play taps a silent instrument prefetch
<sha> feat(reader): latest instrument pick wins, inherit wasPlaying
<sha> feat(reader): pause and alert when changing instruments during playback
<sha> feat(reader): silently prefetch on cache-miss when picking an instrument
<sha> test(reader): teach FakePlaybackController about per-patch cache and prefetch
<sha> feat(playback): adapt isSoundfontCached and prefetchSoundfont to domain resolver
<sha> feat(playback): declare per-patch cache and prefetch on PlaybackController
<sha> docs(reader): spec for cache-aware instrument preload from Inspector
```
