import Domain
import Foundation
import ImportExportAppGroup

public struct IngestSummary: Sendable {
    public let token: UUID
    public let acceptedFiles: [IncomingShareIntent.File]
    public let unsupportedCount: Int

    public init(token: UUID, acceptedFiles: [IncomingShareIntent.File], unsupportedCount: Int) {
        self.token = token
        self.acceptedFiles = acceptedFiles
        self.unsupportedCount = unsupportedCount
    }
}
