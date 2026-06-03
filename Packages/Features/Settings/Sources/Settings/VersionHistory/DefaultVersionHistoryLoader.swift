import Domain
import Foundation
import SettingsLogic

public struct DefaultVersionHistoryLoader: VersionHistoryLoader {
    public enum LoadError: Error {
        case resourceNotFound(name: String)
    }

    private let bundle: Bundle
    private let resourceName: String

    public init(bundle: Bundle = .main, resourceName: String = "VersionHistory") {
        self.bundle = bundle
        self.resourceName = resourceName
    }

    public func load() throws -> [VersionHistoryEntry] {
        guard let url = bundle.url(forResource: resourceName, withExtension: "yml") else {
            throw LoadError.resourceNotFound(name: resourceName)
        }
        // Parsing + locale selection live in the shared SettingsLogic loader so iOS and Android share one path.
        return try YAMLVersionHistoryLoader(data: Data(contentsOf: url)).load()
    }
}
