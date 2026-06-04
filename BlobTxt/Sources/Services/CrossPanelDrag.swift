import Foundation

/// Shared state for a blob drag within the FileNavigator that may cross folder boundaries.
class CrossPanelDrag: ObservableObject {
    @Published var activeBlobID: UUID? = nil
    @Published var activeProjectID: UUID? = nil
    @Published var targetFolderID: UUID? = nil

    func clear() {
        activeBlobID = nil
        activeProjectID = nil
        targetFolderID = nil
    }
}
