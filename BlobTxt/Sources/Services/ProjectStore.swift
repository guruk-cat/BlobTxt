import SwiftUI
import AppKit

class ProjectStore: ObservableObject {
    @Published var currentProject: Project?

    // The current project's navigator tracking mode. Lives here (rather than in the navigator view)
    // so it survives the sidebar closing/reopening, and is persisted per project in `.blobtxt`.
    @Published var trackingMode: TrackingMode = .regular

    // Blaze mark → two-letter abbreviation, read from the current project's `.blobtxt`. The navigator
    // hands this to BlazeTracker so each mark's badge shows the right letters. Seeded with defaults on
    // open when a project has `.blaze/` but no abbreviations recorded yet.
    @Published var markAbbreviations: [String: String] = [:]

    // Default abbreviations for the marks blaze ships with. Custom marks are abbreviated by the user
    // editing `.blobtxt` directly; until then they fall back to a derived two-letter form.
    static let defaultMarkAbbreviations: [String: String] = [
        "note": "NT", "idea": "ID", "try": "TR", "working": "WK",
        "draft": "DR", "review": "RV", "commit": "CM", "shelve": "SH",
    ]

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
    // Reads the project name and tracking mode from the `.blobtxt` marker; creates the marker
    // (with the directory name) if it is absent or carries no name.
    func openProject(at url: URL) {
        var marker = readMarker(at: url)

        let name: String
        if let stored = marker.scalars["name"], !stored.isEmpty {
            name = stored
        } else {
            name = url.lastPathComponent
            marker.scalars["name"] = name
            writeMarker(marker, at: url)
        }
        // Fall back to `.regular` when the key is missing or holds an unrecognized value.
        let mode = marker.scalars["mode"].flatMap(TrackingMode.init(rawValue:)) ?? .regular

        // Seed blaze abbreviations the first time a blaze-tracked project is opened: if `.blaze/`
        // exists but no abbreviations are recorded, write the defaults so they are visible and editable.
        let blazeExists = fileManager.fileExists(
            atPath: url.appendingPathComponent(".blaze").path)
        if blazeExists, (marker.sections["mark_abbreviations"]?.isEmpty ?? true) {
            marker.sections["mark_abbreviations"] = Self.defaultMarkAbbreviations
            writeMarker(marker, at: url)
        }
        let abbreviations = marker.sections["mark_abbreviations"] ?? [:]

        let project = Project(url: url, name: name)
        DispatchQueue.main.async {
            self.currentProject = project
            self.trackingMode = mode
            self.markAbbreviations = abbreviations
        }
        persistLastProject(url)
        addToRecents(url)
    }

    // MARK: - Tracking Mode

    // Updates the navigator tracking mode and persists it to the current project's `.blobtxt`.
    // No-ops when the mode is unchanged or when no project is open.
    func setTrackingMode(_ mode: TrackingMode) {
        guard trackingMode != mode else { return }
        trackingMode = mode
        guard let url = currentProject?.url else { return }
        var marker = readMarker(at: url)
        marker.scalars["mode"] = mode.rawValue
        writeMarker(marker, at: url)
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

    // Moves a blob into `directoryURL`, keeping its filename. Appends a numeric suffix if a file of
    // the same name already lives there. Returns the new URL, or nil if the move failed.
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

    /*
      The `.blobtxt` marker is YAML-shaped but parsed by hand (no YAML library). It has two kinds of
      entries: top-level `key: value` scalars (e.g. `name`, `mode`), and sections — a top-level key
      with an empty value followed by indented `key: value` children (e.g. `mark_abbreviations`).
      Modeling it this way lets callers touch one entry without disturbing the others.
    */
    private struct Marker {
        var scalars: [String: String] = [:]
        var sections: [String: [String: String]] = [:]
    }

    // Scalars are emitted first in this order so the file stays stable across rewrites.
    private let scalarKeyOrder = ["name", "mode"]

    // Parses the `.blobtxt` marker in `directoryURL`. Returns an empty marker when it is absent.
    // A line with leading whitespace is a child of the most recent section header (a top-level key
    // whose value is empty). Top-level `key: value` lines with a value are scalars.
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

    // Writes `marker` back to `.blobtxt`. Known scalars lead in a fixed order, any extras follow;
    // then each non-empty section, separated by a blank line, with its children indented two spaces.
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
