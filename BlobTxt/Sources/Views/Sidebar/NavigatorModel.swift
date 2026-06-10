import SwiftUI

/// A node in the navigator tree: either a folder (which may have children) or a blob (a `.md` file).
final class FileNode: Identifiable {
    let url: URL
    let name: String          // folder name, or blob filename without the `.md` extension
    let isDirectory: Bool
    let children: [FileNode]   // always empty for blobs

    init(url: URL, name: String, isDirectory: Bool, children: [FileNode]) {
        self.url = url
        self.name = name
        self.isDirectory = isDirectory
        self.children = children
    }

    var id: URL { url }
}

/// Owns the navigator's tree state for the current project: the parsed directory tree,
/// which folders are expanded, the context directory for new-item creation, and the
/// FSEvents watcher that keeps the tree in sync with on-disk changes.
final class NavigatorModel: ObservableObject {
    @Published private(set) var rootNodes: [FileNode] = []
    @Published private(set) var expanded: Set<URL> = []

    // The directory new folders/blobs are created in. `nil` means the project root.
    // Maintained by `toggle(_:)` per the rules described there.
    @Published private(set) var contextDir: URL? = nil

    private var projectURL: URL?
    private var watcher: FileSystemWatcher?

    // MARK: - Lifecycle

    // Points the model at a project directory, resetting per-project state and starting the watcher.
    // Re-activating the same project just reloads (e.g. when the view reappears).
    func activate(projectURL: URL) {
        if self.projectURL == projectURL {
            reload()
            return
        }
        self.projectURL = projectURL
        expanded = []
        contextDir = nil
        reload()
        watcher = FileSystemWatcher(url: projectURL) { [weak self] in self?.reload() }
    }

    func deactivate() {
        watcher?.stop()
        watcher = nil
    }

    // MARK: - Creation context

    // Directory in which new folders/blobs are created: the context folder, or the project root.
    var creationDir: URL? { contextDir ?? projectURL }

    // Both create methods return the new item's URL so the caller can begin renaming it.
    @discardableResult
    func createBlob(using store: ProjectStore) -> URL? {
        guard let dir = creationDir else { return nil }
        let url = store.createBlob(in: dir)?.url
        reload()
        return url
    }

    @discardableResult
    func createFolder(using store: ProjectStore) -> URL? {
        guard let dir = creationDir else { return nil }
        let url = store.createFolder(in: dir)
        reload()
        return url
    }

    // MARK: - Rename / delete

    // Renames a node on disk and reloads. Returns the new URL (nil on failure).
    // A folder rename also moves its descendants; their expanded state is dropped on reload.
    @discardableResult
    func rename(_ node: FileNode, to newName: String, using store: ProjectStore) -> URL? {
        let newURL = node.isDirectory
            ? store.renameFolder(url: node.url, to: newName)
            : store.renameBlob(url: node.url, to: newName)
        reload()
        return newURL
    }

    func delete(_ node: FileNode, using store: ProjectStore) {
        if node.isDirectory {
            store.deleteFolder(url: node.url)
        } else {
            store.deleteBlob(url: node.url)
        }
        reload()
    }

    // MARK: - Expand / collapse and context tracking

    /*
      Context-directory rules (see nav-panel-plans §2.3):
      - Expanding a folder makes it the context directory.
      - Collapsing a folder, when the context is that folder or any descendant of it,
        moves the context up to that folder's parent (which may be the project root).
        Collapsing an unrelated folder leaves the context untouched.
      In the sibling case (open A, open B, close B) this yields the project root, since
      B's parent is the root. In the nested case (open A, open A/C, close A/C) it yields A.
    */
    func toggle(_ node: FileNode) {
        guard node.isDirectory else { return }
        if expanded.contains(node.url) {
            expanded.remove(node.url)
            if let ctx = contextDir, ctx == node.url || isDescendant(ctx, of: node.url) {
                contextDir = parentDir(of: node.url)
            }
        } else {
            expanded.insert(node.url)
            contextDir = node.url
        }
    }

    func isExpanded(_ node: FileNode) -> Bool { expanded.contains(node.url) }

    // MARK: - Reload

    // Rebuilds the tree from disk and prunes any expand/context state pointing at folders
    // that no longer exist (e.g. deleted outside the app).
    func reload() {
        guard let projectURL = projectURL else { rootNodes = []; return }
        rootNodes = NavigatorModel.buildNodes(at: projectURL)

        let existingFolders = NavigatorModel.collectFolderURLs(rootNodes)
        expanded.formIntersection(existingFolders)
        if let ctx = contextDir, !existingFolders.contains(ctx) { contextDir = nil }
    }

    // MARK: - Private helpers

    // Returns the parent directory of `url`, or nil if that parent is the project root.
    private func parentDir(of url: URL) -> URL? {
        guard let projectURL = projectURL else { return nil }
        let parent = url.deletingLastPathComponent()
        return parent.standardizedFileURL == projectURL.standardizedFileURL ? nil : parent
    }

    // True if `url` lives anywhere inside `folder`.
    private func isDescendant(_ url: URL, of folder: URL) -> Bool {
        url.path.hasPrefix(folder.path + "/")
    }

    // Recursively reads `directory`, returning folders and `.md` blobs sorted folders-first,
    // then alphabetically (case-insensitive). Hidden/dotfiles and non-.md files are skipped.
    private static func buildNodes(at directory: URL) -> [FileNode] {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        var folders: [FileNode] = []
        var blobs: [FileNode] = []

        for url in contents {
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if isDir {
                folders.append(FileNode(
                    url: url,
                    name: url.lastPathComponent,
                    isDirectory: true,
                    children: buildNodes(at: url)
                ))
            } else if url.pathExtension == "md" {
                blobs.append(FileNode(
                    url: url,
                    name: url.deletingPathExtension().lastPathComponent,
                    isDirectory: false,
                    children: []
                ))
            }
        }

        let byName: (FileNode, FileNode) -> Bool = {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        return folders.sorted(by: byName) + blobs.sorted(by: byName)
    }

    // Flattens all folder URLs in the tree, used to prune stale expand/context state.
    private static func collectFolderURLs(_ nodes: [FileNode]) -> Set<URL> {
        var result: Set<URL> = []
        for node in nodes where node.isDirectory {
            result.insert(node.url)
            result.formUnion(collectFolderURLs(node.children))
        }
        return result
    }
}
