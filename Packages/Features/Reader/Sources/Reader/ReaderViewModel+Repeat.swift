import Domain
import SheetMusicCore

// MARK: - Repeat / loop mutators

extension ReaderViewModel {
    public func advanceRepeatMode() async {
        let next = preferences.repeatMode.next
        await mutatePreferences { $0.repeatMode = next }
    }

    public func setRepeatA() async {
        guard case let .loaded(score) = loadState,
              let cursor = playbackCursor else { return }
        let measure = measureIndex(of: cursor)
        let head = snapMeasureHead(measureIndex: measure, in: score)
        pendingA = head
        await commitPendingRepeat()
    }

    public func setRepeatB() async {
        guard case let .loaded(score) = loadState,
              let cursor = playbackCursor else { return }
        let measure = measureIndex(of: cursor)
        guard let end = snapMeasureEnd(measureIndex: measure, in: score) else { return }
        pendingB = end
        await commitPendingRepeat()
    }

    public func clearRepeatA() async {
        pendingA = nil
        if let existing = preferences.abRepeat {
            pendingB = existing.end
        }
        await mutatePreferences { $0.abRepeat = nil }
    }

    public func clearRepeatB() async {
        pendingB = nil
        if let existing = preferences.abRepeat {
            pendingA = existing.start
        }
        await mutatePreferences { $0.abRepeat = nil }
    }

    func commitPendingRepeat() async {
        let candidateStart = pendingA ?? preferences.abRepeat?.start
        let candidateEnd = pendingB ?? preferences.abRepeat?.end
        guard let start = candidateStart, let end = candidateEnd else {
            // Only one endpoint set so far — leave the persisted range nil.
            await mutatePreferences { $0.abRepeat = nil }
            return
        }
        let normalized = normalize(ABRepeatRange(start: start, end: end))
        pendingA = normalized.start
        pendingB = normalized.end
        await mutatePreferences { $0.abRepeat = normalized }
    }
}
