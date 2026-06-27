import SwiftUI
import AppKit

class ProjectStore: ObservableObject {
    @Published var currentProject: Project?

    // The blob currently open in the editor, or nil when nothing is open (no document, or an image). Set by ContentView; read to gate blob-only menu items (e.g. Open in Mini View).
    @Published var activeBlobURL: URL?

    private let fileManager = FileManager.default

    init() {
        restoreLastProject()
    }

    // MARK: - Project Opening

    // Guards against opening more than one project panel per notification dispatch. `.showProjectPicker` is sometimes delivered to duplicate SwiftUI `onReceive` subscriptions (varies by session), which otherwise fires this once per subscriber — the "have to Cancel three times" bug. The flag is reset on the next runloop tick, after the whole synchronous post dispatch has finished, so the extra observers are coalesced.
    private var isShowingProjectPanel = false

    // Presents an NSOpenPanel for folder selection, then opens the chosen directory as the current project.
    // Uses runModal (not begin): it dismisses the panel before returning, so the panel can't linger after the project window rebuilds. Callers are on the main thread.
    func openProjectWithPanel() {
        guard !isShowingProjectPanel else { return }
        isShowingProjectPanel = true

        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"
        panel.message = "Select a project folder"
        let response = panel.runModal()
        DispatchQueue.main.async { self.isShowingProjectPanel = false }

        if response == .OK, let url = panel.url {
            openProject(at: url)
        }
    }

    // Opens a directory as the current project.
    func openProject(at url: URL) {
        var marker = readMarker(at: url)    // `.blobtxt` marker

        let name: String
        if let stored = marker.scalars["name"], !stored.isEmpty {
            name = stored
        } else {
            name = url.lastPathComponent
            marker.scalars["name"] = name
            writeMarker(marker, at: url)
        }
        let project = Project(url: url, name: name)
        DispatchQueue.main.async {
            self.currentProject = project
        }
        persistLastProject(url)
    }

    // Restores the last opened project from UserDefaults on launch.
    func restoreLastProject() {
        guard let path = UserDefaults.standard.string(forKey: "lastProjectPath") else { return }
        let url = URL(fileURLWithPath: path)
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { return }
        openProject(at: url)
    }

    // MARK: - Blob CRUD

    // Creates an `untitled.md` file in `directoryURL`. Appends a numeric suffix if the name is taken.
    // Returns the new file's URL, or nil if it could not be created.
    func createBlob(in directoryURL: URL) -> URL? {
        let fileURL = resolveUniqueURL(directoryURL.appendingPathComponent("untitled.md"))
        guard fileManager.createFile(atPath: fileURL.path, contents: nil) else { return nil }
        return fileURL
    }

    func deleteBlob(url: URL) {
        try? fileManager.trashItem(at: url, resultingItemURL: nil)
    }

    // Moves a blob into `directoryURL`, keeping its filename. Appends a numeric suffix if a file of the same name already lives there. Returns the new URL, or nil if the move failed.
    @discardableResult
    func moveBlob(url: URL, into directoryURL: URL) -> URL? {
        let target = resolveUniqueURL(directoryURL.appendingPathComponent(url.lastPathComponent))
        do {
            try fileManager.moveItem(at: url, to: target)
            return target
        } catch {
            return nil
        }
    }

    // Renames a file to the given name verbatim, extension included. Appends a numeric suffix if the target name is taken. Returns the new URL, or nil if the move failed.
    @discardableResult
    func renameFile(url: URL, to newName: String) -> URL? {
        let dir = url.deletingLastPathComponent()
        let target = resolveUniqueURL(dir.appendingPathComponent(newName))
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

    func deleteFolder(url: URL) {
        try? fileManager.trashItem(at: url, resultingItemURL: nil)
    }

    // Moves a folder (with everything inside it) into `directoryURL`, keeping its name. Appends a numeric suffix if a folder of the same name already lives there. Returns the new URL, or nil if the move failed. The caller is responsible for rejecting moves into the folder itself or its own descendants (see `NavigatorModel.moveFolder`); the filesystem would otherwise error.
    @discardableResult
    func moveFolder(url: URL, into directoryURL: URL) -> URL? {
        let target = resolveUniqueFolderURL(directoryURL.appendingPathComponent(url.lastPathComponent))
        do {
            try fileManager.moveItem(at: url, to: target)
            return target
        } catch {
            return nil
        }
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

    // The `.blobtxt` marker is YAML-shaped but parsed by hand (no YAML library): top-level `key: value` scalars (e.g. `name`).
    private struct Marker {
        var scalars: [String: String] = [:]
    }

    // Scalars are emitted first in this order so the file stays stable across rewrites.
    private let scalarKeyOrder = ["name"]

    // Parses the `.blobtxt` marker in `directoryURL`. Returns an empty marker when it is absent.
    private func readMarker(at directoryURL: URL) -> Marker {
        let markerURL = directoryURL.appendingPathComponent(".blobtxt")
        guard let content = try? String(contentsOf: markerURL, encoding: .utf8) else { return Marker() }

        var marker = Marker()
        for rawLine in content.components(separatedBy: "\n") {
            if rawLine.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            guard let colon = rawLine.firstIndex(of: ":") else { continue }
            let key = String(rawLine[..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(rawLine[rawLine.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if key.isEmpty { continue }
            marker.scalars[key] = value
        }
        return marker
    }

    // Writes `marker` back to `.blobtxt`. Known scalars lead in a fixed order, any extras follow.
    private func writeMarker(_ marker: Marker, at directoryURL: URL) {
        let markerURL = directoryURL.appendingPathComponent(".blobtxt")

        var lines: [String] = []
        let knownScalars = scalarKeyOrder.filter { marker.scalars[$0] != nil }
        let extraScalars = marker.scalars.keys.filter { !scalarKeyOrder.contains($0) }.sorted()
        for key in knownScalars + extraScalars {
            lines.append("\(key): \(marker.scalars[key]!)")
        }

        let content = lines.joined(separator: "\n") + "\n"
        try? content.write(to: markerURL, atomically: true, encoding: .utf8)
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
}
