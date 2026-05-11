/// Three-state cycle for the Reader's repeat / loop feature.
/// `.off` plays through, `.loopAll` loops the whole score, `.abLoop`
/// loops the user-selected A–B section (measures).
public enum RepeatMode: String, Hashable, Sendable, Codable, CaseIterable {
    case off
    case loopAll
    case abLoop

    /// Cycle order shown on the Inspector's mode button.
    var next: RepeatMode {
        switch self {
        case .off: .loopAll
        case .loopAll: .abLoop
        case .abLoop: .off
        }
    }
}
