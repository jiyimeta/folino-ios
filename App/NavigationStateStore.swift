import Domain
import Foundation
import SwiftUI

/// Persists and restores `AppShellView`'s navigation state across launches:
/// the compact (iPhone) and sidebar (iPad) `NavigationPath` instances and the
/// iPad detail score's identifier. Storage is plain `UserDefaults`; corrupt
/// or forward-incompatible payloads are silently dropped so a fresh launch
/// just starts at the Library root.
@MainActor
final class NavigationStateStore {
    private static let compactPathKey = "NavigationState.compactPath"
    private static let sidebarPathKey = "NavigationState.sidebarPath"
    private static let detailScoreIDKey = "NavigationState.detailScoreID"

    private let defaults: UserDefaults
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func loadCompactPath() -> NavigationPath? {
        loadPath(forKey: Self.compactPathKey)
    }

    func loadSidebarPath() -> NavigationPath? {
        loadPath(forKey: Self.sidebarPathKey)
    }

    func loadDetailScoreID() -> ScoreItemID? {
        guard let data = defaults.data(forKey: Self.detailScoreIDKey) else { return nil }
        return try? decoder.decode(ScoreItemID.self, from: data)
    }

    func save(compact: NavigationPath, sidebar: NavigationPath, detailScoreID: ScoreItemID?) {
        savePath(compact, forKey: Self.compactPathKey)
        savePath(sidebar, forKey: Self.sidebarPathKey)
        if let detailScoreID, let data = try? encoder.encode(detailScoreID) {
            defaults.set(data, forKey: Self.detailScoreIDKey)
        } else {
            defaults.removeObject(forKey: Self.detailScoreIDKey)
        }
    }

    private func loadPath(forKey key: String) -> NavigationPath? {
        guard let data = defaults.data(forKey: key) else { return nil }
        guard let representation = try? decoder.decode(
            NavigationPath.CodableRepresentation.self,
            from: data
        ) else { return nil }
        return NavigationPath(representation)
    }

    private func savePath(_ path: NavigationPath, forKey key: String) {
        guard let representation = path.codable else {
            defaults.removeObject(forKey: key)
            return
        }
        if let data = try? encoder.encode(representation) {
            defaults.set(data, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }
}
