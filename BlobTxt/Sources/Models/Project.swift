import Foundation

// A BlobTxt project: an on-disk directory identified by its URL and named via a `.blobtxt` marker file.
struct Project: Identifiable, Equatable {
    let url: URL
    var name: String

    var id: URL { url }
}
