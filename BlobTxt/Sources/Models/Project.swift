import Foundation

/// Top-level container for a user's project. Persisted to `<projectID>/project.json`.
struct Project: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var folders: [BlobFolder]
    var blobs: [Blob]
    let createdAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        folders: [BlobFolder] = [],
        blobs: [Blob] = [],
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.folders = folders
        self.blobs = blobs
        self.createdAt = createdAt
    }
}
