import Foundation

/// Wraps folder URLs and blob items for use in `FileNavigatorView`.
/// `.ghost` is the drop-target placeholder rendered during drag.
enum NavigatorItem: Identifiable, Equatable {
    case folder(URL)
    case blob(Blob)
    case ghost

    var id: String {
        switch self {
        case .folder(let url): return "folder:" + url.path
        case .blob(let blob):  return "blob:" + blob.url.path
        case .ghost:           return "__ghost__"
        }
    }
}
