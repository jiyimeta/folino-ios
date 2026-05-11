@_exported import SheetMusicCore

/// Module marker. Exists so other layers can verify Domain is linked at
/// runtime, and so test targets can `@testable import Domain` without needing
/// any concrete type. The actual Domain surface is defined in sibling files.
enum DomainModule {
    static let isLinked = true
}
