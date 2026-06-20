import Foundation

// Per-blob metadata, stored as YAML front matter at the top of a `.md` file and edited in the Metadata panel. Every field is optional; an all-blank value serializes to no front matter at all (see `BlobContent.serializeFrontMatter`). `authors` and `institutions` are sequences so each entry is its own editable row in the panel.
struct BlobMetadata: Equatable {
    var title: String = ""
    var authors: [String] = []
    var date: String = ""
    var institutions: [String] = []
}
