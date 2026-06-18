import SwiftUI
import AppKit

class ProjectStore: ObservableObject {
    @Published var currentProject: Project?

    // The current project's navigator tracking mode. Persisted per project in `.blobtxt`.
    @Published var trackingMode: TrackingMode = .regular

    // Not persisted over app sessions; keyed by blob file URL.
    var blobScrollPositions: [URL: Int] = [:]

    // The blob currently open in the editor, or nil when nothing printable is open (no document, or an image). Set by ContentView; read by the File → Print menu item to gate itself.
    @Published var activeBlobURL: URL?

    // The blob shown in the mini view, or nil when the mini view is closed. Session-scoped, never persisted. It is the single source of truth for the "one place per blob" gate: a blob open here cannot also open in the main window, and vice versa.
    @Published var miniViewURL: URL?

    // The front-matter metadata of the blob currently open in the editor, and which blob it belongs to. Populated when `loadBlobContent` parses a file; the Metadata panel reads `activeMetadata` and writes back through `updateActiveMetadata`. While a blob is open this in-memory copy is the source of truth for its front matter — it is what gets serialized on every save.
    @Published private(set) var activeMetadata = BlobMetadata()
    @Published private(set) var activeMetadataURL: URL?

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
    // Reads the file at `url`, parsing its YAML front matter into `activeMetadata` (so the Metadata panel reflects this blob) and returning the body with the front matter stripped off.
    func loadBlobContent(url: URL) -> String? {
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        activeMetadata = parseFrontMatter(from: raw)
        activeMetadataURL = url
        return stripFrontMatter(from: raw)
    }

    // Reads a blob's body (front matter stripped) without touching the active-blob metadata slot.
    // Used to inspect blobs other than the open one — e.g. the Merge Blobs preview.
    func readBody(url: URL) -> String? {
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return stripFrontMatter(from: raw)
    }

    // Writes `body` to the file at `url`, re-attaching front matter ahead of it.
    // For the active blob the in-memory `activeMetadata` is the source of truth, so it is serialized fresh (picking up any panel edits). For any other blob — one we never parsed — the front matter already on disk is preserved instead.
    func saveBlobContent(_ body: String, url: URL) {
        let output: String
        if url == activeMetadataURL {
            if let fm = serializeFrontMatter(activeMetadata) {
                output = fm + "\n" + body
            } else {
                output = body
            }
        } else {
            let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            if let fm = extractFrontMatter(from: existing) {
                output = fm + "\n" + body
            } else {
                output = body
            }
        }
        do {
            try output.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            print("[ProjectStore] Failed to save blob content: \(error)")
        }
    }

    // MARK: - Blob Metadata

    // Write-request from the Metadata panel.
    // Updates the active blob's in-memory metadata and, if it actually changed, rewrites the file's front matter immediately while keeping the body currently on disk. Persisting right away (rather than only on the next body save) means metadata-only edits are not lost when the editor has nothing dirty to trigger a save. A later body save re-serializes the same `activeMetadata`, so body and front matter stay consistent.
    func updateActiveMetadata(_ metadata: BlobMetadata) {
        guard let url = activeMetadataURL, metadata != activeMetadata else { return }
        activeMetadata = metadata
        let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let body = stripFrontMatter(from: existing)
        let output: String
        if let fm = serializeFrontMatter(metadata) {
            output = fm + "\n" + body
        } else {
            output = body
        }
        do {
            try output.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            print("[ProjectStore] Failed to write blob metadata: \(error)")
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
        if let fm = serializeFrontMatter(metadata) {
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

    // Parses the leading YAML front matter into `BlobMetadata`. Only the four known keys are read; `authors` and `institutions` are sequences (`- item` lines following the bare key), the rest are scalars. Unknown keys and a missing front matter block yield an empty `BlobMetadata`.
    private func parseFrontMatter(from content: String) -> BlobMetadata {
        var metadata = BlobMetadata()
        guard content.hasPrefix("---") else { return metadata }
        let lines = content.components(separatedBy: "\n")
        guard let end = (1..<lines.count).first(where: { lines[$0].hasPrefix("---") }) else {
            return metadata
        }

        // The sequence key whose `- item` children we are currently collecting, if any.
        var currentList: String?
        for line in lines[1..<end] {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }

            let isIndented = line.first == " " || line.first == "\t"
            if isIndented, trimmed.hasPrefix("-") {
                let item = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
                switch currentList {
                case "authors":      metadata.authors.append(item)
                case "institutions": metadata.institutions.append(item)
                default:             break
                }
                continue
            }

            guard let colon = trimmed.firstIndex(of: ":") else { continue }
            let key = String(trimmed[..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(trimmed[trimmed.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            switch key {
            case "title":
                metadata.title = value
                currentList = nil
            case "date":
                metadata.date = value
                currentList = nil
            case "authors":
                currentList = "authors"
                if !value.isEmpty { metadata.authors.append(value) }   // tolerate an inline value
            case "institutions":
                currentList = "institutions"
                if !value.isEmpty { metadata.institutions.append(value) }
            default:
                currentList = nil
            }
        }
        return metadata
    }

    // Serializes `metadata` into a front matter block (both `---` delimiters included, no trailing newline).
    // Blank scalars and blank sequence entries are omitted; if nothing remains the whole block is dropped by returning nil. Key order matches the panel: title, authors, date, institutions.
    private func serializeFrontMatter(_ metadata: BlobMetadata) -> String? {
        var lines: [String] = []

        let title = metadata.title.trimmingCharacters(in: .whitespaces)
        if !title.isEmpty { lines.append("title: \(title)") }

        let authors = metadata.authors
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if !authors.isEmpty {
            lines.append("authors:")
            authors.forEach { lines.append("  - \($0)") }
        }

        let date = metadata.date.trimmingCharacters(in: .whitespaces)
        if !date.isEmpty { lines.append("date: \(date)") }

        let institutions = metadata.institutions
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if !institutions.isEmpty {
            lines.append("institutions:")
            institutions.forEach { lines.append("  - \($0)") }
        }

        guard !lines.isEmpty else { return nil }
        return "---\n" + lines.joined(separator: "\n") + "\n---"
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
