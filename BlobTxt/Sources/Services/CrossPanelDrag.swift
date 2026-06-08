import Foundation

/// Shared state for a blob drag within the FileNavigator that may cross folder boundaries.
class CrossPanelDrag: ObservableObject {
    @Published var activeBlobURL: URL? = nil
    @Published var activeProjectURL: URL? = nil
    @Published var targetFolderURL: URL? = nil

    func clear() {
        activeBlobURL = nil
        activeProjectURL = nil
        targetFolderURL = nil
    }
}
