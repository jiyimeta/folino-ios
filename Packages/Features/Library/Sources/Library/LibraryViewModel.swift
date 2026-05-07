import Domain
import Foundation
import Observation

@MainActor
@Observable
public final class LibraryViewModel {
    public let repository: any ScoreLibraryRepository
    public let importer: any ScoreFileImporter
    public let gateway: any ScoreFileGateway
    public let shareService: any ScoreShareService

    public var shareTarget: ShareTarget?
    public var isPreparingShare: Bool = false

    public struct ShareTarget: Identifiable, Equatable, Sendable {
        public let id: UUID
        public let url: URL
        public init(url: URL) {
            id = UUID()
            self.url = url
        }
    }

    public var errorAlertMessage: String?

    /// Set when an import succeeds; the App composition root watches this and
    /// pushes the Reader. Cleared by the watcher after handling.
    public var pendingScoreToOpen: ScoreItem?

    /// Drives the `.fileImporter` sheet.
    public var isFileImporterPresented = false

    /// Set when `prepareImport` returns at least one duplicate. The view
    /// presents a 3-button alert; choosing one of the buttons drives
    /// `commitImport`.
    public var duplicatePrompt: DuplicatePrompt?

    public struct DuplicatePrompt: Identifiable, Equatable {
        public let id = UUID()
        public let plan: ImportPlan
        public let existing: ScoreItem
    }

    public init(
        repository: any ScoreLibraryRepository,
        importer: any ScoreFileImporter,
        gateway: any ScoreFileGateway,
        shareService: any ScoreShareService
    ) {
        self.repository = repository
        self.importer = importer
        self.gateway = gateway
        self.shareService = shareService
    }

    public func toggleFavorite(_ scoreItem: ScoreItem) async {
        var updated = scoreItem
        updated.isFavorite.toggle()
        await save(updated)
    }

    public func delete(_ scoreItem: ScoreItem) async {
        do {
            try await repository.deleteScoreItem(id: scoreItem.id)
        } catch {
            errorAlertMessage = describe(error)
        }
    }

    public func requestShare(_ item: ScoreItem, format: ScoreShareFormat) async {
        isPreparingShare = true
        defer { isPreparingShare = false }
        do {
            let url = try await shareService.prepareShare(item: item, format: format)
            shareTarget = ShareTarget(url: url)
        } catch {
            errorAlertMessage = describe(error)
        }
    }

    public func setTagIDs(_ tagIDs: Set<TagID>, on scoreItem: ScoreItem) async {
        var updated = scoreItem
        updated.tagIDs = tagIDs
        await save(updated)
    }

    func save(_ scoreItem: ScoreItem) async {
        do {
            try await repository.saveScoreItem(scoreItem)
        } catch {
            errorAlertMessage = describe(error)
        }
    }

    /// Called by the `.fileImporter` `onCompletion`. Handles security-scoped
    /// access, prepareImport, and either commits immediately or stages a
    /// duplicate prompt.
    public func startImport(from sourceURL: URL) async {
        let scoped = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if scoped { sourceURL.stopAccessingSecurityScopedResource() }
        }
        let plan: ImportPlan
        do {
            plan = try await importer.prepareImport(sourceURL: sourceURL)
        } catch {
            errorAlertMessage = describe(error)
            return
        }
        if let existing = plan.duplicates.first {
            duplicatePrompt = DuplicatePrompt(plan: plan, existing: existing)
            return
        }
        await commit(plan: plan, decision: .importAsNew)
    }

    public func commit(plan: ImportPlan, decision: ImportDecision) async {
        do {
            let item = try await importer.commitImport(plan, decision: decision)
            pendingScoreToOpen = item
        } catch {
            errorAlertMessage = describe(error)
        }
    }

    private func describe(_ error: Error) -> String {
        if let domain = error as? DomainError {
            switch domain {
            case .unsupportedFormat:
                return String(localized: "folino can't open this file type.")
            case .scoreParseFailed:
                return String(localized: "This file looks corrupted or isn't a valid score.")
            case .persistenceFailed:
                return String(localized: "There was a problem saving the score. Check available storage.")
            case .scoreFileNotFound, .scoreWriteFailed,
                 .soundfontDownloadFailed, .syncFailed, .audioEngineFailed:
                return domain.errorDescription ?? "\(domain)"
            }
        }
        return (error as NSError).localizedDescription
    }
}
