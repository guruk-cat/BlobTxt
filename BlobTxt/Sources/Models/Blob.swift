import Foundation

/// A single document. The file URL is its identity; display name is the filename without the `.md` extension.
struct Blob: Identifiable, Equatable {
    let url: URL
    var displayName: String

    var id: URL { url }
}
