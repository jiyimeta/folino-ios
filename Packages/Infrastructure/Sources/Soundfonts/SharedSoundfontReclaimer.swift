import Foundation

public struct SiblingApp: Sendable, Equatable {
    public let bundleId: String
    public let urlScheme: String
    public init(bundleId: String, urlScheme: String) {
        self.bundleId = bundleId
        self.urlScheme = urlScheme
    }
}

/// Abstracts `UIApplication.canOpenURL` so the reclaim logic stays UIKit-free and unit-testable.
public protocol InstalledAppChecking: Sendable {
    func isInstalled(urlScheme: String) -> Bool
}

/// Reference-counted reclaim of the shared high-quality SoundFont. Pure file I/O over injected directories. The marker
/// contract (`consumers/<bundleId>` whose presence means "opted in", JSON body `{"displayName": …}`) and the delete
/// rule (delete iff this app is opted out AND no installed sibling is opted in) are shared verbatim with VocalTuner —
/// see the shared-soundfont spec.
public struct SharedSoundfontReclaimer: Sendable {
    private nonisolated(unsafe) let fileManager: FileManager
    private let soundfontsDirectory: URL
    private let soundfontFileName: String
    private let minimumValidByteSize: Int64
    private let ownBundleId: String
    private let ownDisplayName: String
    private let siblings: [SiblingApp]
    private let installedChecker: any InstalledAppChecking

    public init(
        fileManager: FileManager = .default,
        soundfontsDirectory: URL,
        soundfontFileName: String,
        minimumValidByteSize: Int64,
        ownBundleId: String,
        ownDisplayName: String,
        siblings: [SiblingApp],
        installedChecker: any InstalledAppChecking,
    ) {
        self.fileManager = fileManager
        self.soundfontsDirectory = soundfontsDirectory
        self.soundfontFileName = soundfontFileName
        self.minimumValidByteSize = minimumValidByteSize
        self.ownBundleId = ownBundleId
        self.ownDisplayName = ownDisplayName
        self.siblings = siblings
        self.installedChecker = installedChecker
    }

    private var consumersDirectory: URL {
        soundfontsDirectory.appendingPathComponent("consumers", isDirectory: true)
    }

    private var soundfontFileURL: URL {
        soundfontsDirectory.appendingPathComponent(soundfontFileName)
    }

    private func markerURL(_ bundleId: String) -> URL {
        consumersDirectory.appendingPathComponent(bundleId)
    }

    /// Publishes this app's opt-in into the shared container. Presence of the marker means "opted in".
    public func syncOwnMarker(isOptedIn: Bool) {
        if isOptedIn {
            try? fileManager.createDirectory(at: consumersDirectory, withIntermediateDirectories: true)
            if let data = try? JSONSerialization.data(withJSONObject: ["displayName": ownDisplayName]) {
                try? data.write(to: markerURL(ownBundleId), options: .atomic)
            }
        } else {
            try? fileManager.removeItem(at: markerURL(ownBundleId))
        }
    }

    /// Display name of an installed sibling that is currently opted in (for the "in use" note), or nil.
    public func siblingInUseDisplayName() -> String? {
        for sibling in siblings where installedChecker.isInstalled(urlScheme: sibling.urlScheme) {
            let url = markerURL(sibling.bundleId)
            guard fileManager.fileExists(atPath: url.path) else { continue }
            if let data = try? Data(contentsOf: url),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: String],
               let name = json["displayName"]
            {
                return name
            }
            return sibling.bundleId // marker present but unreadable — fall back to the bundle id
        }
        return nil
    }

    /// Deletes the shared file iff this app is opted out AND no installed sibling is opted in. Prunes markers belonging
    /// to siblings that are no longer installed. Never touches the file while this app is opted in.
    public func reclaimIfUnused(isOptedIn: Bool) {
        defer { pruneStaleSiblingMarkers() }
        guard isValidSoundfont() else { return }
        let anyInstalledSiblingOptedIn = siblings.contains { sibling in
            installedChecker.isInstalled(urlScheme: sibling.urlScheme)
                && fileManager.fileExists(atPath: markerURL(sibling.bundleId).path)
        }
        if !isOptedIn, !anyInstalledSiblingOptedIn {
            try? fileManager.removeItem(at: soundfontFileURL)
        }
    }

    private func pruneStaleSiblingMarkers() {
        for sibling in siblings where !installedChecker.isInstalled(urlScheme: sibling.urlScheme) {
            try? fileManager.removeItem(at: markerURL(sibling.bundleId))
        }
    }

    private func isValidSoundfont() -> Bool {
        guard let size = try? fileManager.attributesOfItem(atPath: soundfontFileURL.path)[.size] as? Int64 else {
            return false
        }
        return size >= minimumValidByteSize
    }
}
