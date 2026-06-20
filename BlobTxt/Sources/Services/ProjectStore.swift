import SwiftUI
import AppKit

class ProjectStore: ObservableObject {
    @Published var currentProject: Project?

    // The current project's navigator tracking mode. Persisted per project in `.blobtxt`.
    @Published var trackingMode: TrackingMode = .regular

    // The blob currently open in the editor, or nil when nothing printable is open (no document, or an image). Set by ContentView; read by the File → Print menu item to gate itself.
    @Published var activeBlobURL: URL?

    // The BlobContent open in the main editor, or nil when nothing is open. The main editor sets it on mount; the Metadata panel binds to its metadata. The mini view never sets it, so the panel always reflects the main window.
    @Published var activeContent: BlobContent?

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
        let mode = marker.scalars["mode"].flatMap(TrackingMode.init(rawValue:)) ?? .regular

        let project = Project(url: url, name: name)
        DispatchQueue.main.async {
            self.currentProject = project
            self.trackingMode = mode
        }
        persistLastProject(url)
        addToRecents(url)
    }

    // MARK: - Tracking Mode

    // Updates the navigator tracking mode and persists it to the current project's `.blobtxt`.
    func setTrackingMode(_ mode: TrackingMode) {
        guard trackingMode != mode else { return }
        trackingMode = mode
        guard let url = currentProject?.url else { return }
        var marker = readMarker(at: url)
        marker.scalars["mode"] = mode.rawValue
        writeMarker(marker, at: url)
    }

    // Restores the last opened project from UserDefaults on launch.
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

    // Reads a blob's body (front matter stripped) without opening it as a live document.
    // Used to inspect blobs other than the open one — e.g. the Merge Blobs preview.
    func readBody(url: URL) -> String? {
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return BlobContent.stripFrontMatter(from: raw)
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

    // Creates a new blob in `directoryURL` from a base name, metadata, and body — used by Merge Blobs.
    // The name gets a `.md` extension if it lacks one, with a numeric suffix appended if it is taken.
    // Metadata is serialized to front matter ahead of the body, exactly as a normal save would write it.
    // Returns the new file's URL, or nil if it could not be created.
    @discardableResult
    func createBlob(named name: String, metadata: BlobMetadata, body: String, in directoryURL: URL) -> URL? {
        var fileName = name.trimmingCharacters(in: .whitespaces)
        if !fileName.lowercased().hasSuffix(".md") { fileName += ".md" }
        let target = resolveUniqueURL(directoryURL.appendingPathComponent(fileName))

        let contents: String
        if let fm = BlobContent.serializeFrontMatter(metadata) {
            contents = fm + "\n" + body
        } else {
            contents = body
        }
        do {
            try contents.write(to: target, atomically: true, encoding: .utf8)
            return target
        } catch {
            print("[ProjectStore] Failed to create merged blob: \(error)")
            return nil
        }
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

    // The `.blobtxt` marker is YAML-shaped but parsed by hand (no YAML library). It has two kinds of entries: top-level `key: value` scalars (e.g. `name`, `mode`), and sections — a top-level key with an empty value followed by indented `key: value` children. Modeling it this way lets callers touch one entry without disturbing the others.
    private struct Marker {
        var scalars: [String: String] = [:]
        var sections: [String: [String: String]] = [:]
    }

    // Scalars are emitted first in this order so the file stays stable across rewrites.
    private let scalarKeyOrder = ["name", "mode"]

    // Parses the `.blobtxt` marker in `directoryURL`. Returns an empty marker when it is absent.
    // A line with leading whitespace is a child of the most recent section header (a top-level key whose value is empty). Top-level `key: value` lines with a value are scalars.
    private func readMarker(at directoryURL: URL) -> Marker {
        let markerURL = directoryURL.appendingPathComponent(".blobtxt")
        guard let content = try? String(contentsOf: markerURL, encoding: .utf8) else { return Marker() }

        var marker = Marker()
        var currentSection: String?
        for rawLine in content.components(separatedBy: "\n") {
            if rawLine.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            let isIndented = rawLine.first == " " || rawLine.first == "\t"
            guard let colon = rawLine.firstIndex(of: ":") else { continue }
            let key = String(rawLine[..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(rawLine[rawLine.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if key.isEmpty { continue }

            if isIndented {
                if let section = currentSection { marker.sections[section, default: [:]][key] = value }
            } else if value.isEmpty {
                currentSection = key
                if marker.sections[key] == nil { marker.sections[key] = [:] }
            } else {
                marker.scalars[key] = value
                currentSection = nil
            }
        }
        return marker
    }

    // Writes `marker` back to `.blobtxt`. Known scalars lead in a fixed order, any extras follow; then each non-empty section, separated by a blank line, with its children indented two spaces.
    private func writeMarker(_ marker: Marker, at directoryURL: URL) {
        let markerURL = directoryURL.appendingPathComponent(".blobtxt")

        var lines: [String] = []
        let knownScalars = scalarKeyOrder.filter { marker.scalars[$0] != nil }
        let extraScalars = marker.scalars.keys.filter { !scalarKeyOrder.contains($0) }.sorted()
        for key in knownScalars + extraScalars {
            lines.append("\(key): \(marker.scalars[key]!)")
        }
        for section in marker.sections.keys.sorted() {
            let entries = marker.sections[section]!
            guard !entries.isEmpty else { continue }
            lines.append("")
            lines.append("\(section):")
            for key in entries.keys.sorted() {
                lines.append("  \(key): \(entries[key]!)")
            }
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

    private func addToRecents(_ url: URL) {
        var paths = UserDefaults.standard.stringArray(forKey: "recentProjectPaths") ?? []
        paths.removeAll { $0 == url.path }
        paths.insert(url.path, at: 0)
        if paths.count > 10 { paths = Array(paths.prefix(10)) }
        UserDefaults.standard.set(paths, forKey: "recentProjectPaths")
    }
}
