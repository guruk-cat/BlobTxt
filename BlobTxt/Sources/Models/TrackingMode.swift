import Foundation

/// The file navigator's display mode. Persisted per project in the `.blobtxt` marker,
/// so the raw values double as the on-disk serialization and must stay stable.
enum TrackingMode: String, CaseIterable, Hashable {
    case regular, git

    var label: String {
        switch self {
        case .regular: return "REGULAR"
        case .git:     return "GIT"
        }
    }
}
