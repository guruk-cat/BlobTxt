import Foundation

/// The file navigator's three-way display mode. Persisted per project in the `.blobtxt` marker,
/// so the raw values double as the on-disk serialization and must stay stable.
enum TrackingMode: String, CaseIterable, Hashable {
    case regular, git, blaze

    var label: String {
        switch self {
        case .regular: return "REGULAR"
        case .git:     return "GIT"
        case .blaze:   return "BLAZE"
        }
    }
}
