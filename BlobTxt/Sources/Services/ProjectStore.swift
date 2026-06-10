import SwiftUI
import AppKit

class ProjectStore: ObservableObject {
    @Published var currentProject: Project?

    // Not persisted; keyed by blob file URL.
    var blobScrollPositions: [URL: Int] = [:]

    private let fileManager = FileManager.default

    init() {
        restoreLastProject()
    }

    // MARK: - Project Opening

    // Presents an NSOpenPanel for folder selection, then opens the chosen directory as the current project.
    func openProjectWithPanel() {
        DispatchQueue.main.async {
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.allowsMultipleSelection = false
            panel.prompt = "Open"
            panel.message = "Select a project folder"
            panel.begin { [weak self] response in
                guard response == .OK, let url = panel.url else { return }
                self?.openProject(at: url)
            }
        }
    }

    // Opens a directory as the current project.
    // Reads the project name from the `.blobtxt` marker; creates the marker if absent.
    func openProject(at url: URL) {
        let name = readOrCreateBlobtxt(at: url)
        let project = Project(url: url, name: name)
        DispatchQueue.main.async {
            self.currentProject = project
        }
        persistLastProject(url)
        addToRecents(url)
    }

    // Restores the last opened project from UserDefaults on launch.
    // Silently skips if the stored path no longer points to a valid directory.
    func restoreLastProject() {
        guard let path = UserDefaults.standard.string(forKey: "lastProjectPath") else { return }
        let url = URL(fileURLWithPath: path)
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { return }
        openProject(at: url)
    }

    // MARK: - Recent Projects

    // Returns the most-recently-opened project URLs (up to 10), newest first.
    var recentProjectURLs: [URL] {
        let paths = UserDefaults.standard.stringArray(forKey: "recentProjectPaths") ?? []
        return paths.compactMap { URL(fileURLWithPath: $0) }
    }

    // MARK: - Blob Content I/O

    // Reads the file at `url` and strips any YAML front matter before returning the body.
    // Returns nil if the file cannot be read.
    func loadBlobContent(url: URL) -> String? {
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return stripFrontMatter(from: raw)
    }

    // Writes `body` to the file at `url`.
    // Any YAML front matter already present in the file is preserved and written before the body.
    func saveBlobContent(_ body: String, url: URL) {
        let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let output: String
        if let fm = extractFrontMatter(from: existing) {
            output = fm + "\n" + body
        } else {
            output = body
        }
        do {
            try output.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            print("[ProjectStore] Failed to save blob content: \(error)")
        }
    }

    // MARK: - Blob CRUD

    // Creates an `untitled.md` file in `directoryURL`. Appends a numeric suffix if the name is taken.
    // Returns the new Blob, or nil if the file could not be created.
    func createBlob(in directoryURL: URL) -> Blob? {
        let baseURL = directoryURL.appendingPathComponent("untitled.md")
        let fileURL = resolveUniqueURL(baseURL)
        guard fileManager.createFile(atPath: fileURL.path, contents: nil) else { return nil }
        let displayName = fileURL.deletingPathExtension().lastPathComponent
        return Blob(url: fileURL, displayName: displayName)
    }

    // Moves the blob to the system Trash (recoverable) rather than deleting it outright.
    func deleteBlob(url: URL) {
        try? fileManager.trashItem(at: url, resultingItemURL: nil)
    }

    // Renames a blob, keeping the `.md` extension. Appends a numeric suffix if the target name is taken.
    // Returns the new URL, or nil if the move failed.
    @discardableResult
    func renameBlob(url: URL, to newName: String) -> URL? {
        let dir = url.deletingLastPathComponent()
        let target = resolveUniqueURL(dir.appendingPathComponent(newName + ".md"))
        do {
            try fileManager.moveItem(at: url, to: target)
            return target
        } catch {
            return nil
        }
    }

    // MARK: - Folder CRUD

    // Creates a folder named `name` in `directoryURL`. Appends a numeric suffix if the name is taken.
    // Returns the new folder URL, or nil if it could not be created.
    @discardableResult
    func createFolder(in directoryURL: URL, name: String = "untitled") -> URL? {
        let folderURL = resolveUniqueFolderURL(directoryURL.appendingPathComponent(name))
        do {
            try fileManager.createDirectory(at: folderURL, withIntermediateDirectories: false)
            return folderURL
        } catch {
            return nil
        }
    }

    // Moves the directory and all its contents to the system Trash (recoverable).
    func deleteFolder(url: URL) {
        try? fileManager.trashItem(at: url, resultingItemURL: nil)
    }

    // Renames a folder. Appends a numeric suffix if the target name is taken.
    // Returns the new URL, or nil if the move failed.
    @discardableResult
    func renameFolder(url: URL, to newName: String) -> URL? {
        let target = resolveUniqueFolderURL(url.deletingLastPathComponent().appendingPathComponent(newName))
        do {
            try fileManager.moveItem(at: url, to: target)
            return target
        } catch {
            return nil
        }
    }

    // MARK: - Private Helpers

    // Reads `name` from the `.blobtxt` marker in `directoryURL`.
    // If the marker is absent or contains no `name:` key, it is created using the directory name.
    private func readOrCreateBlobtxt(at directoryURL: URL) -> String {
        let markerURL = directoryURL.appendingPathComponent(".blobtxt")
        if let content = try? String(contentsOf: markerURL, encoding: .utf8) {
            for line in content.components(separatedBy: "\n") {
                if line.hasPrefix("name:") {
                    let name = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                    if !name.isEmpty { return name }
                }
            }
        }
        let name = directoryURL.lastPathComponent
        let markerContent = "name: \(name)\n"
        try? markerContent.write(to: markerURL, atomically: true, encoding: .utf8)
        return name
    }

    // Returns `content` with its leading YAML front matter block removed.
    // Front matter is a block that begins and ends with a line containing only `---`.
    // If no front matter is detected, the original string is returned unchanged.
    private func stripFrontMatter(from content: String) -> String {
        guard content.hasPrefix("---") else { return content }
        let lines = content.components(separatedBy: "\n")
        for i in 1..<lines.count {
            if lines[i].hasPrefix("---") {
                return lines[(i + 1)...].joined(separator: "\n")
            }
        }
        return content
    }

    // Returns the raw front matter block (both `---` delimiters included) from `content`, or nil if absent.
    private func extractFrontMatter(from content: String) -> String? {
        guard content.hasPrefix("---") else { return nil }
        let lines = content.components(separatedBy: "\n")
        for i in 1..<lines.count {
            if lines[i].hasPrefix("---") {
                return lines[0...i].joined(separator: "\n")
            }
        }
        return nil
    }

    // Returns a URL that does not already exist, appending a numeric suffix (e.g. `untitled-2.md`) if needed.
    private func resolveUniqueURL(_ url: URL) -> URL {
        guard fileManager.fileExists(atPath: url.path) else { return url }
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        let dir = url.deletingLastPathComponent()
        var i = 2
        while true {
            let candidate = dir.appendingPathComponent("\(base)-\(i).\(ext)")
            if !fileManager.fileExists(atPath: candidate.path) { return candidate }
            i += 1
        }
    }

    // Returns a folder URL that does not already exist, appending a numeric suffix (e.g. `untitled-2`) if needed.
    // Separate from `resolveUniqueURL` because folders have no file extension to preserve.
    private func resolveUniqueFolderURL(_ url: URL) -> URL {
        guard fileManager.fileExists(atPath: url.path) else { return url }
        let base = url.lastPathComponent
        let dir = url.deletingLastPathComponent()
        var i = 2
        while true {
            let candidate = dir.appendingPathComponent("\(base)-\(i)")
            if !fileManager.fileExists(atPath: candidate.path) { return candidate }
            i += 1
        }
    }

    private func persistLastProject(_ url: URL) {
        UserDefaults.standard.set(url.path, forKey: "lastProjectPath")
    }

    private func addToRecents(_ url: URL) {
        var paths = UserDefaults.standard.stringArray(forKey: "recentProjectPaths") ?? []
        paths.removeAll { $0 == url.path }
        paths.insert(url.path, at: 0)
        if paths.count > 10 { paths = Array(paths.prefix(10)) }
        UserDefaults.standard.set(paths, forKey: "recentProjectPaths")
    }
}
