import Foundation

/// A single document. Metadata fields (`title`, `author`) are persisted in `project.json`;
/// content is stored separately at `<projectID>/<blobID>.json` as TipTap JSON.
struct Blob: Codable, Identifiable, Equatable {
    let id: UUID
    var folderID: UUID?
    var sortOrder: Int
    let createdAt: Date
    var updatedAt: Date
    var title: String?
    var author: String?

    init(
        id: UUID = UUID(),
        folderID: UUID? = nil,
        sortOrder: Int = 0,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        title: String? = nil,
        author: String? = nil
    ) {
        self.id = id
        self.folderID = folderID
        self.sortOrder = sortOrder
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.title = title
        self.author = author
    }
}
