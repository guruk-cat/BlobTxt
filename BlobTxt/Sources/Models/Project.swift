import Foundation

/// A project directory opened by the user. Identity is the directory URL.
/// The display name is read from `.blobtxt` or falls back to the directory's last path component.
struct Project: Identifiable, Equatable {
    let url: URL
    var name: String

    var id: URL { url }
}
