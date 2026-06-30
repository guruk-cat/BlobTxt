import Foundation

// A BlobTxt project: an on-disk directory identified by its URL and named after the directory itself.
struct Project: Identifiable, Equatable {
    let url: URL
    var name: String

    var id: URL { url }
}
