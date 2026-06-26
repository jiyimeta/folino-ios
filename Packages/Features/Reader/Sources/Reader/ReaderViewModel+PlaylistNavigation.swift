import Domain
import Foundation

/// Manual previous / next score navigation within a playlist, driving the transport's leading backward and trailing
/// forward buttons. Auto-advance at end-of-score lives on `ReaderViewModel` itself; this is the user-initiated jump.
extension ReaderViewModel {
    /// The current score's position within the live playlist queue, or `nil` when standalone / no longer live.
    private func currentPlaylistPosition() -> (queue: [Domain.ScoreItemID], index: Int)? {
        let queue = currentPlaylistQueue()
        guard let index = queue.firstIndex(of: scoreItem.id) else { return nil }
        return (queue, index)
    }

    /// True when traversing a playlist and a score precedes the current one — gates the previous-score jump.
    var hasPreviousPlaylistScore: Bool {
        guard let position = currentPlaylistPosition() else { return false }
        return position.index > 0
    }

    /// True when traversing a playlist and a score follows the current one — gates the next-score button.
    var hasNextPlaylistScore: Bool {
        guard let position = currentPlaylistPosition() else { return false }
        return position.index < position.queue.count - 1
    }

    /// Jump to the previous live score in the playlist, preserving the current play/pause state. No-op at the head of
    /// the queue or when standalone.
    func goToPreviousScore() async {
        guard let position = currentPlaylistPosition(), position.index > 0,
              let previous = repository.scoreItems.first(where: { $0.id == position.queue[position.index - 1] })
        else { return }
        await advance(to: previous, autoPlay: playbackSession.isPlaying)
    }

    /// Jump to the next live score in the playlist, preserving the current play/pause state. No-op at the tail of the
    /// queue or when standalone.
    func goToNextScore() async {
        guard let position = currentPlaylistPosition(), position.index < position.queue.count - 1,
              let next = repository.scoreItems.first(where: { $0.id == position.queue[position.index + 1] })
        else { return }
        await advance(to: next, autoPlay: playbackSession.isPlaying)
    }
}
