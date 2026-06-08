import Foundation

/// A single Markdown document identified by its file URL.
struct Blob: Identifiable, Equatable {
    let url: URL
    var displayName: String  // filename stem, not including the `.md` extension

    var id: URL { url }
}
