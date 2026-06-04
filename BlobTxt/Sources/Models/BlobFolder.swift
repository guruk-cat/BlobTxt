import Foundation

/// A named collection for organizing blobs within a project.
struct BlobFolder: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var sortOrder: Int

    init(
        id: UUID = UUID(),
        name: String,
        sortOrder: Int = 0
    ) {
        self.id = id
        self.name = name
        self.sortOrder = sortOrder
    }
}
