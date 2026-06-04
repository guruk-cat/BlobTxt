import SwiftUI
import WebKit

class ProjectStore: ObservableObject {
    @Published var projects: [Project] = []

    // Set by `EditView.onAppear`/`onDisappear`. Controls whether File → Export to Document is enabled.
    @Published var activeEditorBlobID: UUID? = nil

    var blobScrollPositions: [UUID: Int] = [:] // keyed by blobID; not persisted

    private let fileManager = FileManager.default
    private let rootPath: String

    init() {
        self.rootPath = NSHomeDirectory() + "/Documents/BlobTxt"
        ensureRootDirectory()
        loadProjects()
    }

    // MARK: - Initialization

    private func ensureRootDirectory() {
        if !fileManager.fileExists(atPath: rootPath) {
            try? fileManager.createDirectory(
                atPath: rootPath,
                withIntermediateDirectories: true,
                attributes: nil
            )
        }
    }

    private func loadProjects() {
        guard fileManager.fileExists(atPath: rootPath) else { return }

        guard let contents = try? fileManager.contentsOfDirectory(atPath: rootPath) else { return }

        var loadedProjects: [Project] = []
        for item in contents {
            let itemPath = rootPath + "/" + item
            var isDir: ObjCBool = false
            guard fileManager.fileExists(atPath: itemPath, isDirectory: &isDir), isDir.boolValue else {
                continue
            }

            let projectFile = itemPath + "/project.json"
            guard fileManager.fileExists(atPath: projectFile) else { continue }

            do {
                let data = try Data(contentsOf: URL(fileURLWithPath: projectFile))
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                let project = try decoder.decode(Project.self, from: data)
                loadedProjects.append(project)
            } catch {
                print("Failed to load project at \(projectFile): \(error)")
            }
        }

        loadedProjects.sort { $0.createdAt < $1.createdAt }
        DispatchQueue.main.async {
            self.projects = loadedProjects
        }
    }

    // MARK: - Project CRUD

    func createProject(name: String) -> Project {
        let project = Project(name: name)
        let projectPath = rootPath + "/" + project.id.uuidString
        do {
            try fileManager.createDirectory(
                atPath: projectPath,
                withIntermediateDirectories: true,
                attributes: nil
            )
        } catch {
            print("Failed to create project directory: \(error)")
            return project
        }

        save(project)
        DispatchQueue.main.async {
            self.projects.append(project)
            self.projects.sort { $0.createdAt < $1.createdAt }
        }
        return project
    }

    func deleteProject(_ projectID: UUID) {
        let projectPath = rootPath + "/" + projectID.uuidString
        do {
            try fileManager.removeItem(atPath: projectPath)
        } catch {
            print("Failed to delete project directory: \(error)")
        }

        DispatchQueue.main.async {
            self.projects.removeAll { $0.id == projectID }
        }
    }

    func renameProject(_ projectID: UUID, to name: String) {
        mutateProject(projectID) { project in
            project.name = name
        }
    }

    // MARK: - Folder CRUD

    func createFolder(in projectID: UUID, name: String) -> BlobFolder {
        guard let projectIndex = projectIndex(projectID) else { return BlobFolder(name: name) }

        var project = projects[projectIndex]
        var folder = BlobFolder(name: name)
        // Below the current minimum so the new folder appears first; rebuildRootSortOrders normalizes to 0-based indices.
        folder.sortOrder = (project.folders.min { $0.sortOrder < $1.sortOrder }?.sortOrder ?? 0) - 1
        project.folders.append(folder)
        rebuildRootSortOrders(&project)

        updateProject(project)
        return folder
    }

    func deleteFolder(_ folderID: UUID, in projectID: UUID) {
        guard let projectIndex = projectIndex(projectID) else { return }

        var project = projects[projectIndex]

        project.folders.removeAll { $0.id == folderID }

        // Delete blob files from disk before removing from project
        let blobsInFolder = project.blobs.filter { $0.folderID == folderID }
        let projectPath = rootPath + "/" + projectID.uuidString
        for blob in blobsInFolder {
            let blobFile = projectPath + "/" + blob.id.uuidString + ".json"
            try? fileManager.removeItem(atPath: blobFile)
        }

        project.blobs.removeAll { $0.folderID == folderID }

        updateProject(project)
    }

    func renameFolder(_ folderID: UUID, in projectID: UUID, to name: String) {
        guard let projectIndex = projectIndex(projectID) else { return }

        var project = projects[projectIndex]

        if let index = project.folders.firstIndex(where: { $0.id == folderID }) {
            project.folders[index].name = name
        }

        updateProject(project)
    }

    // MARK: - Blob CRUD

    func createBlob(in projectID: UUID, folderID: UUID? = nil) -> Blob {
        guard let projectIndex = projectIndex(projectID) else { return Blob() }

        var project = projects[projectIndex]
        let blob = Blob(folderID: folderID)

        if let folderID = folderID {
            // Insert before first existing blob in folder
            let firstFolderSortOrder = project.blobs
                .filter { $0.folderID == folderID }
                .min { $0.sortOrder < $1.sortOrder }?
                .sortOrder ?? 0
            var newBlob = blob
            newBlob.sortOrder = firstFolderSortOrder - 1
            project.blobs.append(newBlob)
            rebuildFolderSortOrders(&project, folderID: folderID)
        } else {
            // Insert before first existing root blob
            let firstRootBlobSortOrder = project.blobs
                .filter { $0.folderID == nil }
                .min { $0.sortOrder < $1.sortOrder }
                .map { $0.sortOrder }

            if let firstSortOrder = firstRootBlobSortOrder {
                var newBlob = blob
                newBlob.sortOrder = firstSortOrder - 1
                project.blobs.append(newBlob)
                rebuildRootSortOrders(&project)
            } else {
                let maxSortOrder = project.blobs
                    .filter { $0.folderID == nil }
                    .max { $0.sortOrder < $1.sortOrder }?
                    .sortOrder ?? -1
                var newBlob = blob
                newBlob.sortOrder = maxSortOrder + 1
                project.blobs.append(newBlob)
            }
        }

        updateProject(project)
        return blob
    }

    func deleteBlob(_ blobID: UUID, in projectID: UUID) {
        guard let projectIndex = projectIndex(projectID) else { return }

        var project = projects[projectIndex]

        if let blobIndex = project.blobs.firstIndex(where: { $0.id == blobID }) {
            let blob = project.blobs[blobIndex]
            let folderID = blob.folderID

            project.blobs.remove(at: blobIndex)

            // Delete blob file from disk
            let projectPath = rootPath + "/" + projectID.uuidString
            let blobFile = projectPath + "/" + blobID.uuidString + ".json"
            try? fileManager.removeItem(atPath: blobFile)

            // Rebuild sort orders for affected context
            if let folderID = folderID {
                rebuildFolderSortOrders(&project, folderID: folderID)
            } else {
                rebuildRootSortOrders(&project)
            }
        }

        updateProject(project)
    }

    func moveBlobToRoot(_ blobID: UUID, in projectID: UUID) {
        guard let projectIndex = projectIndex(projectID) else { return }

        var project = projects[projectIndex]

        if let index = project.blobs.firstIndex(where: { $0.id == blobID }) {
            let oldFolderID = project.blobs[index].folderID
            project.blobs[index].folderID = nil

            // Assign sortOrder before first existing root blob
            let firstRootBlobSortOrder = project.blobs
                .filter { $0.folderID == nil && $0.id != blobID }
                .min { $0.sortOrder < $1.sortOrder }
                .map { $0.sortOrder }

            if let firstSortOrder = firstRootBlobSortOrder {
                project.blobs[index].sortOrder = firstSortOrder - 1
            } else {
                let maxSortOrder = project.blobs
                    .filter { $0.folderID == nil }
                    .max { $0.sortOrder < $1.sortOrder }?
                    .sortOrder ?? -1
                project.blobs[index].sortOrder = maxSortOrder + 1
            }

            // Rebuild sort orders for both contexts
            if let oldFolderID = oldFolderID {
                rebuildFolderSortOrders(&project, folderID: oldFolderID)
            }
            rebuildRootSortOrders(&project)
        }

        updateProject(project)
    }

    // MARK: - Sort Order Management

    func rebuildSortOrders(in projectID: UUID, context folderID: UUID?) {
        guard let projectIndex = projectIndex(projectID) else { return }

        var project = projects[projectIndex]

        if let folderID = folderID {
            rebuildFolderSortOrders(&project, folderID: folderID)
        } else {
            rebuildRootSortOrders(&project)
        }

        updateProject(project)
    }

    func moveItem(in projectID: UUID, fromIndex: Int, toIndex: Int, context folderID: UUID?) {
        guard let projectIndex = projectIndex(projectID) else { return }
        guard fromIndex != toIndex else { return }

        var project = projects[projectIndex]

        if let folderID = folderID {
            // Folder context: all items are blobs; fromIndex/toIndex are 0-based within this folder's visible blobs
            var blobs = project.blobs
                .filter { $0.folderID == folderID }
                .sorted { $0.sortOrder < $1.sortOrder }
            guard fromIndex >= 0, fromIndex < blobs.count,
                  toIndex >= 0, toIndex < blobs.count else { return }
            let moved = blobs.remove(at: fromIndex)
            blobs.insert(moved, at: toIndex)
            // Write new sort orders directly — don't call rebuildFolderSortOrders which would
            // re-sort by the old (unchanged) sortOrder values and undo the move.
            for (i, blob) in blobs.enumerated() {
                if let idx = project.blobs.firstIndex(where: { $0.id == blob.id }) {
                    project.blobs[idx].sortOrder = i
                }
            }
        } else {
            // Root context: fromIndex/toIndex into folders-first ordering (folders, then root blobs)
            let sortedFolders = project.folders.sorted { $0.sortOrder < $1.sortOrder }
            let sortedRootBlobs = project.blobs
                .filter { $0.folderID == nil }
                .sorted { $0.sortOrder < $1.sortOrder }
            let folderCount = sortedFolders.count

            if fromIndex < folderCount {
                // Moving a folder; toIndex must also be within the folder section
                guard toIndex >= 0, toIndex < folderCount else { return }
                var folders = sortedFolders
                let moved = folders.remove(at: fromIndex)
                folders.insert(moved, at: toIndex)
                for (i, folder) in folders.enumerated() {
                    if let idx = project.folders.firstIndex(where: { $0.id == folder.id }) {
                        project.folders[idx].sortOrder = i
                    }
                }
            } else {
                // Moving a root blob; convert from allDashItems-space to blob-section-space
                let blobFromIndex = fromIndex - folderCount
                let blobToIndex   = toIndex   - folderCount
                guard blobFromIndex >= 0, blobFromIndex < sortedRootBlobs.count,
                      blobToIndex   >= 0, blobToIndex   < sortedRootBlobs.count else { return }
                var blobs = sortedRootBlobs
                let moved = blobs.remove(at: blobFromIndex)
                blobs.insert(moved, at: blobToIndex)
                for (i, blob) in blobs.enumerated() {
                    if let idx = project.blobs.firstIndex(where: { $0.id == blob.id }) {
                        project.blobs[idx].sortOrder = i
                    }
                }
            }
        }

        updateProject(project)
    }

    func moveBlobToFolder(_ blobID: UUID, to folderID: UUID, in projectID: UUID) {
        guard let projectIndex = projectIndex(projectID) else { return }

        var project = projects[projectIndex]

        if let index = project.blobs.firstIndex(where: { $0.id == blobID }) {
            let oldFolderID = project.blobs[index].folderID
            project.blobs[index].folderID = folderID
            project.blobs[index].sortOrder = (project.blobs
                .filter { $0.folderID == folderID && $0.id != blobID }
                .min { $0.sortOrder < $1.sortOrder }?
                .sortOrder ?? 0) - 1

            // Rebuild sort orders for both old and new contexts
            if let oldFolderID = oldFolderID {
                rebuildFolderSortOrders(&project, folderID: oldFolderID)
            } else {
                rebuildRootSortOrders(&project)
            }
            rebuildFolderSortOrders(&project, folderID: folderID)
        }

        updateProject(project)
    }

    // MARK: - Blob Content I/O

    func loadBlobContent(blobID: UUID, in projectID: UUID) -> String? {
        let blobFile = rootPath + "/" + projectID.uuidString + "/" + blobID.uuidString + ".json"
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: blobFile)) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - Blob Excerpt

    struct BlobExcerpt {
        var title: String? // first heading's text, or blob.title metadata if set
        var body: String? // plain text from all non-heading nodes (used by sidebar)
        var bodyAttributed: AttributedString? // rich text body with inline marks (used by card previews)
    }

    // Parses TipTap JSON and returns a structured excerpt.
    // Title = first heading node's text (only one, regardless of level).
    // Body  = text from all non-heading nodes with inline bold/italic/underline preserved.
    func loadBlobExcerpt(blobID: UUID, in projectID: UUID) -> BlobExcerpt {
        guard let jsonString = loadBlobContent(blobID: blobID, in: projectID),
              let data = jsonString.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let topNodes = root["content"] as? [[String: Any]] else {
            return BlobExcerpt()
        }

        var titleParts: [String] = []
        var bodyNodes:  [[String: Any]] = []
        var foundTitle = false

        for node in topNodes {
            let type = node["type"] as? String
            if type == "heading" {
                if !foundTitle {
                    extractText(from: node, into: &titleParts)
                    foundTitle = true
                }
                // subsequent headings intentionally skipped
            } else {
                bodyNodes.append(node)
            }
        }

        // Join text within each node with "" (text nodes already carry their own spacing),
        // then join top-level nodes with " " so paragraphs stay separated.
        var bodyParts: [String] = []
        for node in bodyNodes {
            var parts: [String] = []
            extractText(from: node, into: &parts)
            let nodeText = parts.joined()
            if !nodeText.isEmpty { bodyParts.append(nodeText) }
        }

        let title = titleParts.joined().trimmingCharacters(in: .whitespacesAndNewlines)
        let body  = bodyParts.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        let bodyAttributed = buildAttributedBody(from: bodyNodes)

        var excerpt = BlobExcerpt(
            title:         title.isEmpty ? nil : title,
            body:          body.isEmpty  ? nil : body,
            bodyAttributed: bodyAttributed
        )
        // User-supplied metadata title overrides content-derived title.
        if let project = projects.first(where: { $0.id == projectID }),
           let blob = project.blobs.first(where: { $0.id == blobID }),
           let metaTitle = blob.title, !metaTitle.isEmpty {
            excerpt.title = metaTitle
        }
        return excerpt
    }

    // MARK: - Search

    struct SearchResult: Identifiable {
        var id: UUID { blob.id }
        var blob: Blob
        var matchCount: Int
        var excerpt: BlobExcerpt
    }

    struct SnippetMatch: Identifiable {
        var id: Int { occurrenceIndex }
        var occurrenceIndex: Int
        var snippet: String
    }

    // Searches all blobs in the given project context (project root or folder).
    func searchBlobs(in projectID: UUID, folderID: UUID?, query: String) -> [SearchResult] {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty,
              let project = projects.first(where: { $0.id == projectID }) else { return [] }
        let blobs: [Blob]
        if let folderID {
            blobs = project.blobs.filter { $0.folderID == folderID }.sorted { $0.sortOrder < $1.sortOrder }
        } else {
            blobs = project.blobs.sorted { $0.sortOrder < $1.sortOrder }
        }
        let q = query.lowercased()
        return blobs.compactMap { blob in
            guard let text = loadBlobPlainText(blobID: blob.id, in: projectID, maxWords: .max) else { return nil }
            let count = countOccurrences(of: q, in: text.lowercased())
            guard count > 0 else { return nil }
            return SearchResult(blob: blob, matchCount: count, excerpt: loadBlobExcerpt(blobID: blob.id, in: projectID))
        }
    }

    // Extracts snippet matches (surrounding context) for each occurrence of a query in a blob.
    func searchSnippets(blobID: UUID, in projectID: UUID, query: String, snippetRadius: Int = 60) -> [SnippetMatch] {
        guard !query.isEmpty,
              let text = loadBlobPlainText(blobID: blobID, in: projectID, maxWords: .max) else { return [] }
        var matches: [SnippetMatch] = []
        var searchRange = text.startIndex..<text.endIndex
        var index = 0
        while let range = text.range(of: query, options: .caseInsensitive, range: searchRange) {
            let textLen = text.count
            let matchPos = text.distance(from: text.startIndex, to: range.lowerBound)
            let matchEnd = text.distance(from: text.startIndex, to: range.upperBound)
            let snippetStartOff = max(0, matchPos - snippetRadius)
            let snippetEndOff   = min(textLen, matchEnd + snippetRadius)
            let snippetStart = text.index(text.startIndex, offsetBy: snippetStartOff)
            let snippetEnd   = text.index(text.startIndex, offsetBy: snippetEndOff)
            var snippet = String(text[snippetStart..<snippetEnd])
            if snippetStartOff > 0  { snippet = "…" + snippet }
            if snippetEndOff < textLen { snippet = snippet + "…" }
            matches.append(SnippetMatch(occurrenceIndex: index, snippet: snippet))
            searchRange = range.upperBound..<text.endIndex
            index += 1
        }
        return matches
    }

    // Replaces all case-insensitive occurrences of `find` with `replace` in the given blobs' content.
    func replaceAllInBlobs(blobIDs: [UUID], in projectID: UUID, find: String, replace: String) {
        guard !find.isEmpty else { return }
        for blobID in blobIDs {
            guard let jsonString = loadBlobContent(blobID: blobID, in: projectID),
                  let data = jsonString.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            let modified = replaceInNode(json, find: find, replace: replace) as! [String: Any]
            guard let newData = try? JSONSerialization.data(withJSONObject: modified),
                  let newString = String(data: newData, encoding: .utf8) else { continue }
            saveBlobContent(newString, blobID: blobID, in: projectID)
        }
    }

    private func countOccurrences(of query: String, in text: String) -> Int {
        var count = 0
        var range = text.startIndex..<text.endIndex
        while let found = text.range(of: query, range: range) {
            count += 1
            range = found.upperBound..<text.endIndex
        }
        return count
    }

    private func replaceInNode(_ node: Any, find: String, replace: String) -> Any {
        if var dict = node as? [String: Any] {
            if dict["type"] as? String == "text", let text = dict["text"] as? String {
                dict["text"] = text.replacingOccurrences(of: find, with: replace, options: .caseInsensitive)
                return dict
            }
            if let children = dict["content"] as? [Any] {
                dict["content"] = children.map { replaceInNode($0, find: find, replace: replace) }
            }
            return dict
        }
        if let array = node as? [Any] {
            return array.map { replaceInNode($0, find: find, replace: replace) }
        }
        return node
    }

    // MARK: - Blob Outline

    struct BlobHeading {
        var level: Int    // 1–6, matching TipTap heading levels
        var text: String
    }

    // Returns every heading node from a blob's TipTap JSON, in document order.
    func loadBlobHeadings(blobID: UUID, in projectID: UUID) -> [BlobHeading] {
        guard let jsonString = loadBlobContent(blobID: blobID, in: projectID),
              let data = jsonString.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let topNodes = root["content"] as? [[String: Any]] else {
            return []
        }

        var headings: [BlobHeading] = []
        for node in topNodes {
            guard node["type"] as? String == "heading",
                  let attrs = node["attrs"] as? [String: Any],
                  let level = attrs["level"] as? Int else { continue }
            var parts: [String] = []
            extractText(from: node, into: &parts)
            let text = parts.joined().trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                headings.append(BlobHeading(level: level, text: text))
            }
        }
        return headings
    }

    // MARK: - Attributed body builder

    private func buildAttributedBody(from nodes: [[String: Any]]) -> AttributedString? {
        var result = AttributedString()
        var isFirst = true

        for node in nodes {
            let part = attributedStringFromNode(node)
            guard !part.characters.isEmpty else { continue }
            if !isFirst {
                var sep = AttributedString(" ")
                sep.font = .system(size: 16, design: .monospaced)
                result += sep
            }
            result += part
            isFirst = false
        }

        return result.characters.isEmpty ? nil : result
    }

    private func attributedStringFromNode(_ node: [String: Any]) -> AttributedString {
        guard let type = node["type"] as? String else { return AttributedString() }

        if type == "text" {
            guard let text = node["text"] as? String, !text.isEmpty else { return AttributedString() }
            var segment = AttributedString(text)
            let marks = node["marks"] as? [[String: Any]] ?? []
            var isBold = false
            var isItalic = false
            var isUnderline = false
            for mark in marks {
                switch mark["type"] as? String {
                case "bold":      isBold = true
                case "italic":    isItalic = true
                case "underline": isUnderline = true
                default: break
                }
            }
            var font = Font.system(size: 16, weight: isBold ? .bold : .regular, design: .monospaced)
            if isItalic { font = font.italic() }
            segment.font = font
            if isUnderline { segment.underlineStyle = Text.LineStyle(pattern: .solid) }
            return segment
        } else {
            var result = AttributedString()
            if let children = node["content"] as? [[String: Any]] {
                for child in children { result += attributedStringFromNode(child) }
            }
            return result
        }
    }

    // Extracts plain text from a blob's TipTap JSON.
    // Pass maxWords: .max to get the full text (e.g. for clipboard copy).
    func loadBlobPlainText(blobID: UUID, in projectID: UUID, maxWords: Int = 30) -> String? {
        guard let jsonString = loadBlobContent(blobID: blobID, in: projectID),
              let data = jsonString.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) else { return nil }

        // Walk top-level nodes, joining text within each node with "" to avoid
        // double spaces around bold/italic runs, then join nodes with " ".
        var topParts: [String] = []
        if let dict = root as? [String: Any],
           let topNodes = dict["content"] as? [Any] {
            for node in topNodes {
                var parts: [String] = []
                extractText(from: node, into: &parts)
                let t = parts.joined()
                if !t.isEmpty { topParts.append(t) }
            }
        }
        let full = topParts.joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !full.isEmpty else { return nil }
        if maxWords == .max { return full }
        let words = full.split(separator: " ", omittingEmptySubsequences: true).prefix(maxWords)
        return words.joined(separator: " ")
    }

    // Counts words in a blob's body text, excluding footnote nodes.
    func loadBlobWordCount(blobID: UUID, in projectID: UUID) -> Int {
        guard let jsonString = loadBlobContent(blobID: blobID, in: projectID),
              let data = jsonString.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let topNodes = root["content"] as? [Any] else { return 0 }
        var parts: [String] = []
        for node in topNodes {
            guard let dict = node as? [String: Any] else { continue }
            if dict["type"] as? String == "footnotes" { continue }
            extractText(from: dict, into: &parts)
        }
        let full = parts.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return full.isEmpty ? 0 : full.split(separator: " ", omittingEmptySubsequences: true).count
    }

    func updateBlobMetadata(blobID: UUID, in projectID: UUID, title: String?, author: String?) {
        mutateProject(projectID) { project in
            if let index = project.blobs.firstIndex(where: { $0.id == blobID }) {
                project.blobs[index].title = title.map { $0.isEmpty ? nil : $0 } ?? nil
                project.blobs[index].author = author.map { $0.isEmpty ? nil : $0 } ?? nil
            }
        }
    }

    // Generates HTML from a blob's TipTap JSON, preserving headings, lists, and inline marks.
    func loadBlobHTML(blobID: UUID, in projectID: UUID) -> String? {
        guard let jsonString = loadBlobContent(blobID: blobID, in: projectID),
              let data = jsonString.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let topNodes = root["content"] as? [[String: Any]] else { return nil }
        let html = topNodes.map { renderNodeHTML($0) }.joined()
        return html.isEmpty ? nil : html
    }

    private func renderNodeHTML(_ node: [String: Any]) -> String {
        guard let type = node["type"] as? String else { return "" }
        let children = node["content"] as? [[String: Any]] ?? []
        switch type {
        case "paragraph":
            return "<p>" + children.map { renderNodeHTML($0) }.joined() + "</p>"
        case "heading":
            let level = (node["attrs"] as? [String: Any])?["level"] as? Int ?? 1
            return "<h\(level)>" + children.map { renderNodeHTML($0) }.joined() + "</h\(level)>"
        case "bulletList":
            return "<ul>" + children.map { renderNodeHTML($0) }.joined() + "</ul>"
        case "orderedList":
            return "<ol>" + children.map { renderNodeHTML($0) }.joined() + "</ol>"
        case "listItem":
            return "<li>" + children.map { renderNodeHTML($0) }.joined() + "</li>"
        case "blockquote":
            return "<blockquote>" + children.map { renderNodeHTML($0) }.joined() + "</blockquote>"
        case "hardBreak":
            return "<br>"
        case "text":
            guard let text = node["text"] as? String else { return "" }
            let escaped = text
                .replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
            let marks = node["marks"] as? [[String: Any]] ?? []
            return marks.reduce(escaped) { result, mark in
                let attrs = mark["attrs"] as? [String: Any] ?? [:]
                switch mark["type"] as? String {
                case "bold":      return "<strong>\(result)</strong>"
                case "italic":    return "<em>\(result)</em>"
                case "underline": return "<u>\(result)</u>"
                case "strike":    return "<s>\(result)</s>"
                case "code":      return "<code>\(result)</code>"
                case "link":
                    let href = (attrs["href"] as? String ?? "").replacingOccurrences(of: "\"", with: "&quot;")
                    guard !href.isEmpty else { return result }
                    return "<a href=\"\(href)\">\(result)</a>"
                default:          return result
                }
            }
        case "image":
            let attrs = node["attrs"] as? [String: Any] ?? [:]
            let src = attrs["src"] as? String ?? ""
            let alt = (attrs["alt"] as? String ?? "")
                .replacingOccurrences(of: "\"", with: "&quot;")
            return "<figure><img src=\"\(src)\" alt=\"\(alt)\"></figure>"
        case "footnoteReference":
            let refAttrs = node["attrs"] as? [String: Any] ?? [:]
            let refNumber = refAttrs["referenceNumber"] as? String ?? "0"
            let refDataId = refAttrs["data-id"] as? String ?? ""
            let refDataIdAttr = refDataId.isEmpty ? "" : " data-id=\"\(refDataId)\""
            return "<sup><a href=\"#fn:\(refNumber)\" id=\"ref:\(refNumber)\" class=\"footnote-ref\"\(refDataIdAttr) data-reference-number=\"\(refNumber)\">[\(refNumber)]</a></sup>"
        case "footnotes":
            return "<ol class=\"footnotes\">" + children.map { renderNodeHTML($0) }.joined() + "</ol>"
        case "footnote":
            let fnAttrs = node["attrs"] as? [String: Any] ?? [:]
            let footnoteId = fnAttrs["id"] as? String ?? "fn:0"
            let fnDataId = fnAttrs["data-id"] as? String ?? ""
            let fnDataIdAttr = fnDataId.isEmpty ? "" : " data-id=\"\(fnDataId)\""
            let refNumber = footnoteId.replacingOccurrences(of: "fn:", with: "")
            let content = children.map { renderNodeHTML($0) }.joined()
            return "<li id=\"\(footnoteId)\"\(fnDataIdAttr)>\(content) <a href=\"#ref:\(refNumber)\" class=\"footnote-backlink\">↑</a></li>"
        default:
            return children.map { renderNodeHTML($0) }.joined()
        }
    }

    private func extractText(from node: Any, into result: inout [String]) {
        guard let dict = node as? [String: Any] else { return }
        if dict["type"] as? String == "text", let text = dict["text"] as? String {
            result.append(text)
        }
        if let children = dict["content"] as? [Any] {
            for child in children { extractText(from: child, into: &result) }
        }
    }

    func saveBlobContent(_ json: String, blobID: UUID, in projectID: UUID) {
        let blobFile = rootPath + "/" + projectID.uuidString + "/" + blobID.uuidString + ".json"
        guard let data = json.data(using: .utf8) else { return }
        do {
            try data.write(to: URL(fileURLWithPath: blobFile), options: .atomic)
            mutateProject(projectID) { project in
                if let index = project.blobs.firstIndex(where: { $0.id == blobID }) {
                    project.blobs[index].updatedAt = Date()
                }
            }
        } catch {
            print("[ProjectStore] Failed to save blob content: \(error)")
        }
    }

    // MARK: - Print

    // Generates an HTML document from the blob's TipTap content, injects the active print profile
    // CSS and `--ft-print-img-max-width` variable, then presents the system print sheet (macOS 13+).
    func printBlob(blobID: UUID, in projectID: UUID) {
        guard let fragment = loadBlobHTML(blobID: blobID, in: projectID) else { return }

        let profileName = UserDefaults.standard.string(forKey: "printProfile") ?? "default"
        let css = loadPrintProfileCSS(profileName: profileName) ?? loadFirstAvailablePrintProfileCSS() ?? ""

        let excerpt = loadBlobExcerpt(blobID: blobID, in: projectID)
        let rawTitle: String
        if let heading = excerpt.title {
            rawTitle = heading
        } else if let body = excerpt.body {
            let words = body.split(separator: " ", omittingEmptySubsequences: true).prefix(6)
            rawTitle = words.joined(separator: " ")
        } else {
            rawTitle = "Untitled"
        }
        let imgMaxWidth = UserDefaults.standard.bool(forKey: "imageLimitHalfWidth") ? "50%" : "100%"
        let document = """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="UTF-8">
        <style>:root { --ft-print-img-max-width: \(imgMaxWidth); }
        \(css)</style>
        </head>
        <body>\(fragment)</body>
        </html>
        """

        if #available(macOS 13, *) {
            BlobPrinter.start(html: document, jobTitle: rawTitle)
        }
    }

    private func loadPrintProfileCSS(profileName: String) -> String? {
        guard let url = Bundle.main.url(
            forResource: profileName,
            withExtension: "css",
            subdirectory: "print-profiles"
        ) else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    private func loadFirstAvailablePrintProfileCSS() -> String? {
        guard let urls = Bundle.main.urls(forResourcesWithExtension: "css", subdirectory: "print-profiles"),
              let firstURL = urls.first else { return nil }
        return try? String(contentsOf: firstURL, encoding: .utf8)
    }

    // MARK: - Export to DOCX

    // Walks the blob's TipTap node tree, produces OOXML XML parts, bundles them into a `.docx`
    // archive via `/usr/bin/zip`, and returns `(data:suggestedName:)`. Returns `nil` on any failure.
    func exportBlobDocx(blobID: UUID, in projectID: UUID) -> (data: Data, suggestedName: String)? {
        guard let jsonString = loadBlobContent(blobID: blobID, in: projectID),
              let jsonData = jsonString.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              let topNodes = root["content"] as? [[String: Any]] else { return nil }

        let ctx = DocxContext()
        var bodyParagraphs: [String] = []
        for (i, node) in topNodes.enumerated() {
            let prevWasBlockquote = i > 0 && (topNodes[i - 1]["type"] as? String) == "blockquote"
            bodyParagraphs.append(contentsOf: docxBlock(node, ctx: ctx, followsBlockquote: prevWasBlockquote))
        }

        let excerpt = loadBlobExcerpt(blobID: blobID, in: projectID)
        let rawTitle: String
        if let h = excerpt.title {
            rawTitle = h
        } else if let b = excerpt.body {
            rawTitle = b.split(separator: " ", omittingEmptySubsequences: true).prefix(6).joined(separator: " ")
        } else {
            rawTitle = "Untitled"
        }
        let safeTitle = rawTitle
            .components(separatedBy: CharacterSet(charactersIn: "/\\:*?\"<>|"))
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let suggestedName = safeTitle.isEmpty ? "Untitled" : safeTitle

        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("blobtxt-docx-\(UUID().uuidString)")
        let fm = FileManager.default
        do {
            for sub in ["", "_rels", "word", "word/_rels"] {
                try fm.createDirectory(at: tmpDir.appendingPathComponent(sub), withIntermediateDirectories: true)
            }
            func write(_ content: String, to path: String) throws {
                try content.write(to: tmpDir.appendingPathComponent(path), atomically: true, encoding: .utf8)
            }
            try write(docxContentTypesXML(), to: "[Content_Types].xml")
            try write(docxRootRelsXML(), to: "_rels/.rels")
            try write(docxDocumentRelsXML(ctx: ctx), to: "word/_rels/document.xml.rels")
            try write(docxStylesXML(), to: "word/styles.xml")
            try write(docxNumberingXML(), to: "word/numbering.xml")
            try write(docxDocumentXML(bodyParagraphs: bodyParagraphs), to: "word/document.xml")
            try write(docxFootnotesXML(ctx: ctx), to: "word/footnotes.xml")

            let outURL = tmpDir.appendingPathComponent("\(suggestedName).docx")
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
            proc.currentDirectoryURL = tmpDir
            proc.arguments = ["-r", outURL.path, "[Content_Types].xml", "_rels", "word"]
            try proc.run()
            proc.waitUntilExit()
            guard proc.terminationStatus == 0 else { return nil }

            let zipData = try Data(contentsOf: outURL)
            try? fm.removeItem(at: tmpDir)
            return (data: zipData, suggestedName: "\(suggestedName).docx")
        } catch {
            try? fm.removeItem(at: tmpDir)
            print("[ProjectStore] DOCX export error: \(error)")
            return nil
        }
    }

    // MARK: DOCX: Context

    // Accumulates state during the node tree walk that can only be resolved after the full tree is visited:
    // hyperlink relationships (written to `word/_rels/document.xml.rels`) and footnote XML (`word/footnotes.xml`).
    // A class so it can be mutated in place as it's threaded through the recursive `docxBlock`/`docxInline` calls.
    private final class DocxContext {
        private(set) var hyperlinks: [(id: String, url: String)] = []
        private(set) var footnoteXML: [String] = []

        func rIdForHyperlink(url: String) -> String {
            if let existing = hyperlinks.first(where: { $0.url == url }) { return existing.id }
            let id = "rId\(hyperlinks.count + 4)"
            hyperlinks.append((id: id, url: url))
            return id
        }

        func addFootnote(_ xml: String) { footnoteXML.append(xml) }
    }

    // MARK: DOCX: Block rendering

    // Converts a block-level TipTap node to one or more `<w:p>` strings.
    // `listType` propagates the enclosing list kind ("bullet"/"ordered") down through `listItem` to `paragraph`.
    // `followsBlockquote` applies `BodyTextContinuation` style to the immediately following paragraph.
    private func docxBlock(_ node: [String: Any], ctx: DocxContext, listType: String? = nil, followsBlockquote: Bool = false) -> [String] {
        guard let type = node["type"] as? String else { return [] }
        let children = node["content"] as? [[String: Any]] ?? []
        switch type {
        case "paragraph":
            let pPr: String
            if let lt = listType {
                let style = lt == "bullet" ? "ListBullet" : "ListNumber"
                pPr = "<w:pPr><w:pStyle w:val=\"\(style)\"/></w:pPr>"
            } else if followsBlockquote {
                pPr = "<w:pPr><w:pStyle w:val=\"BodyTextContinuation\"/></w:pPr>"
            } else { pPr = "" }
            let runs = children.map { docxInline($0, ctx: ctx) }.joined()
            return ["<w:p>\(pPr)\(runs)</w:p>"]
        case "heading":
            let level = (node["attrs"] as? [String: Any])?["level"] as? Int ?? 1
            let runs = children.map { docxInline($0, ctx: ctx) }.joined()
            return ["<w:p><w:pPr><w:pStyle w:val=\"Heading\(level)\"/></w:pPr>\(runs)</w:p>"]
        case "bulletList":
            return children.flatMap { docxBlock($0, ctx: ctx, listType: "bullet") }
        case "orderedList":
            return children.flatMap { docxBlock($0, ctx: ctx, listType: "ordered") }
        case "listItem":
            return children.flatMap { docxBlock($0, ctx: ctx, listType: listType) }
        case "blockquote":
            return children.flatMap { child -> [String] in
                guard (child["type"] as? String) == "paragraph" else {
                    return docxBlock(child, ctx: ctx)
                }
                let runs = (child["content"] as? [[String: Any]] ?? []).map { docxInline($0, ctx: ctx) }.joined()
                return ["<w:p><w:pPr><w:pStyle w:val=\"BlockQuote\"/></w:pPr>\(runs)</w:p>"]
            }
        case "footnotes":
            for child in children {
                if let xml = docxFootnoteEntry(child, ctx: ctx) { ctx.addFootnote(xml) }
            }
            return []
        default:
            return children.flatMap { docxBlock($0, ctx: ctx, listType: listType) }
        }
    }

    // MARK: DOCX: Inline rendering

    // Converts an inline TipTap node to an OOXML run string (`<w:r>`, `<w:hyperlink>`, or `<w:footnoteReference>`).
    private func docxInline(_ node: [String: Any], ctx: DocxContext) -> String {
        guard let type = node["type"] as? String else { return "" }
        switch type {
        case "text":
            guard let text = node["text"] as? String else { return "" }
            let marks = node["marks"] as? [[String: Any]] ?? []
            let t = docxXMLEscape(text)
            if let linkMark = marks.first(where: { $0["type"] as? String == "link" }),
               let href = (linkMark["attrs"] as? [String: Any])?["href"] as? String, !href.isEmpty {
                let rId = ctx.rIdForHyperlink(url: href)
                let otherMarks = marks.filter { $0["type"] as? String != "link" }
                let rPr = docxRPr(marks: otherMarks, extraStyle: "Hyperlink")
                return "<w:hyperlink r:id=\"\(rId)\" w:history=\"1\"><w:r>\(rPr)<w:t xml:space=\"preserve\">\(t)</w:t></w:r></w:hyperlink>"
            }
            let rPr = docxRPr(marks: marks)
            return "<w:r>\(rPr)<w:t xml:space=\"preserve\">\(t)</w:t></w:r>"
        case "hardBreak":
            return "<w:r><w:br/></w:r>"
        case "footnoteReference":
            let attrs = node["attrs"] as? [String: Any] ?? [:]
            let num = Int(attrs["referenceNumber"] as? String ?? "0") ?? 0
            return "<w:r><w:rPr><w:rStyle w:val=\"FootnoteReference\"/></w:rPr><w:footnoteReference w:id=\"\(num)\"/></w:r>"
        default:
            return ""
        }
    }

    private func docxRPr(marks: [[String: Any]], extraStyle: String? = nil) -> String {
        var props: [String] = []
        if let s = extraStyle { props.append("<w:rStyle w:val=\"\(s)\"/>") }
        for mark in marks {
            switch mark["type"] as? String {
            case "bold":      props.append("<w:b/>")
            case "italic":    props.append("<w:i/>")
            case "underline": props.append("<w:u w:val=\"single\"/>")
            case "strike":    props.append("<w:strike/>")
            case "code":      props.append("<w:rStyle w:val=\"InlineCode\"/>")
            default: break
            }
        }
        return props.isEmpty ? "" : "<w:rPr>\(props.joined())</w:rPr>"
    }

    private func docxXMLEscape(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    // MARK: DOCX: Footnote entry

    // Converts a TipTap `footnote` node to a `<w:footnote>` XML string for `word/footnotes.xml`.
    private func docxFootnoteEntry(_ node: [String: Any], ctx: DocxContext) -> String? {
        guard (node["type"] as? String) == "footnote",
              let attrs = node["attrs"] as? [String: Any],
              let fnId = attrs["id"] as? String else { return nil }
        let num = Int(fnId.replacingOccurrences(of: "fn:", with: "")) ?? 0
        let children = node["content"] as? [[String: Any]] ?? []
        var paragraphs = ""
        for (i, child) in children.enumerated() {
            guard (child["type"] as? String) == "paragraph" else { continue }
            let runs = (child["content"] as? [[String: Any]] ?? []).map { docxInline($0, ctx: ctx) }.joined()
            if i == 0 {
                let fnRef = "<w:r><w:rPr><w:rStyle w:val=\"FootnoteReference\"/></w:rPr><w:footnoteRef/></w:r><w:r><w:t xml:space=\"preserve\"> </w:t></w:r>"
                paragraphs += "<w:p><w:pPr><w:pStyle w:val=\"FootnoteText\"/></w:pPr>\(fnRef)\(runs)</w:p>"
            } else {
                paragraphs += "<w:p><w:pPr><w:pStyle w:val=\"FootnoteText\"/></w:pPr>\(runs)</w:p>"
            }
        }
        if paragraphs.isEmpty {
            paragraphs = "<w:p><w:pPr><w:pStyle w:val=\"FootnoteText\"/></w:pPr><w:r><w:rPr><w:rStyle w:val=\"FootnoteReference\"/></w:rPr><w:footnoteRef/></w:r></w:p>"
        }
        return "<w:footnote w:type=\"normal\" w:id=\"\(num)\">\(paragraphs)</w:footnote>"
    }

    // MARK: DOCX: XML file generators

    private func docxContentTypesXML() -> String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
          <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
          <Default Extension="xml" ContentType="application/xml"/>
          <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
          <Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>
          <Override PartName="/word/footnotes.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.footnotes+xml"/>
          <Override PartName="/word/numbering.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.numbering+xml"/>
        </Types>
        """
    }

    private func docxRootRelsXML() -> String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
          <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
        </Relationships>
        """
    }

    private func docxDocumentRelsXML(ctx: DocxContext) -> String {
        var rels = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
          <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>
          <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/footnotes" Target="footnotes.xml"/>
          <Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/numbering" Target="numbering.xml"/>
        """
        for link in ctx.hyperlinks {
            let url = link.url.replacingOccurrences(of: "&", with: "&amp;")
            rels += "\n  <Relationship Id=\"\(link.id)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/hyperlink\" Target=\"\(url)\" TargetMode=\"External\"/>"
        }
        rels += "\n</Relationships>"
        return rels
    }

    private func docxDocumentXML(bodyParagraphs: [String]) -> String {
        let body = bodyParagraphs.isEmpty ? "<w:p/>" : bodyParagraphs.joined()
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
          <w:body>\(body)<w:sectPr/></w:body>
        </w:document>
        """
    }

    private func docxFootnotesXML(ctx: DocxContext) -> String {
        let entries = ctx.footnoteXML.joined()
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:footnotes xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
          <w:footnote w:type="separator" w:id="-1"><w:p><w:r><w:separator/></w:r></w:p></w:footnote>
          <w:footnote w:type="continuationSeparator" w:id="0"><w:p><w:r><w:continuationSeparator/></w:r></w:p></w:footnote>
          \(entries)
        </w:footnotes>
        """
    }

    private func docxStylesXML() -> String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
          <w:style w:type="paragraph" w:default="1" w:styleId="Normal">
            <w:name w:val="Normal"/>
            <w:pPr><w:spacing w:after="160" w:line="276" w:lineRule="auto"/></w:pPr>
            <w:rPr><w:sz w:val="24"/><w:szCs w:val="24"/></w:rPr>
          </w:style>
          <w:style w:type="paragraph" w:styleId="Heading1">
            <w:name w:val="heading 1"/>
            <w:basedOn w:val="Normal"/>
            <w:pPr><w:keepNext/><w:spacing w:before="240" w:after="60"/><w:outlineLvl w:val="0"/></w:pPr>
            <w:rPr><w:b/><w:sz w:val="40"/><w:szCs w:val="40"/></w:rPr>
          </w:style>
          <w:style w:type="paragraph" w:styleId="Heading2">
            <w:name w:val="heading 2"/>
            <w:basedOn w:val="Normal"/>
            <w:pPr><w:keepNext/><w:spacing w:before="200" w:after="40"/><w:outlineLvl w:val="1"/></w:pPr>
            <w:rPr><w:b/><w:sz w:val="32"/><w:szCs w:val="32"/></w:rPr>
          </w:style>
          <w:style w:type="paragraph" w:styleId="Heading3">
            <w:name w:val="heading 3"/>
            <w:basedOn w:val="Normal"/>
            <w:pPr><w:keepNext/><w:spacing w:before="160" w:after="40"/><w:outlineLvl w:val="2"/></w:pPr>
            <w:rPr><w:b/><w:i/><w:sz w:val="28"/><w:szCs w:val="28"/></w:rPr>
          </w:style>
          <w:style w:type="paragraph" w:styleId="ListBullet">
            <w:name w:val="List Bullet"/>
            <w:basedOn w:val="Normal"/>
            <w:pPr><w:numPr><w:ilvl w:val="0"/><w:numId w:val="1"/></w:numPr></w:pPr>
          </w:style>
          <w:style w:type="paragraph" w:styleId="ListNumber">
            <w:name w:val="List Number"/>
            <w:basedOn w:val="Normal"/>
            <w:pPr><w:numPr><w:ilvl w:val="0"/><w:numId w:val="2"/></w:numPr></w:pPr>
          </w:style>
          <w:style w:type="paragraph" w:styleId="FootnoteText">
            <w:name w:val="footnote text"/>
            <w:basedOn w:val="Normal"/>
            <w:pPr><w:spacing w:after="0"/></w:pPr>
            <w:rPr><w:sz w:val="20"/><w:szCs w:val="20"/></w:rPr>
          </w:style>
          <w:style w:type="character" w:styleId="FootnoteReference">
            <w:name w:val="footnote reference"/>
            <w:rPr><w:vertAlign w:val="superscript"/></w:rPr>
          </w:style>
          <w:style w:type="character" w:styleId="Hyperlink">
            <w:name w:val="Hyperlink"/>
            <w:rPr><w:color w:val="0563C1"/><w:u w:val="single"/></w:rPr>
          </w:style>
          <w:style w:type="paragraph" w:styleId="BlockQuote">
            <w:name w:val="Block Quote"/>
            <w:basedOn w:val="Normal"/>
            <w:pPr><w:ind w:left="720" w:right="720"/><w:spacing w:before="120" w:after="120"/></w:pPr>
          </w:style>
          <w:style w:type="paragraph" w:styleId="BodyTextContinuation">
            <w:name w:val="Body Text Continuation"/>
            <w:basedOn w:val="Normal"/>
            <w:pPr><w:ind w:firstLine="0"/></w:pPr>
          </w:style>
          <w:style w:type="character" w:styleId="InlineCode">
            <w:name w:val="Inline Code"/>
            <w:rPr><w:rFonts w:ascii="Courier New" w:hAnsi="Courier New"/></w:rPr>
          </w:style>
        </w:styles>
        """
    }

    private func docxNumberingXML() -> String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:numbering xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
          <w:abstractNum w:abstractNumId="0">
            <w:multiLevelType w:val="hybridMultilevel"/>
            <w:lvl w:ilvl="0">
              <w:start w:val="1"/>
              <w:numFmt w:val="bullet"/>
              <w:lvlText w:val="&#x2022;"/>
              <w:lvlJc w:val="left"/>
              <w:pPr><w:ind w:left="720" w:hanging="360"/></w:pPr>
            </w:lvl>
          </w:abstractNum>
          <w:abstractNum w:abstractNumId="1">
            <w:multiLevelType w:val="hybridMultilevel"/>
            <w:lvl w:ilvl="0">
              <w:start w:val="1"/>
              <w:numFmt w:val="decimal"/>
              <w:lvlText w:val="%1."/>
              <w:lvlJc w:val="left"/>
              <w:pPr><w:ind w:left="720" w:hanging="360"/></w:pPr>
            </w:lvl>
          </w:abstractNum>
          <w:num w:numId="1"><w:abstractNumId w:val="0"/></w:num>
          <w:num w:numId="2"><w:abstractNumId w:val="1"/></w:num>
        </w:numbering>
        """
    }

    // MARK: - Private Helpers

    private func save(_ project: Project) {
        let projectPath = rootPath + "/" + project.id.uuidString
        let projectFile = projectPath + "/project.json"

        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(project)
            try data.write(to: URL(fileURLWithPath: projectFile))
        } catch {
            print("Failed to save project: \(error)")
        }
    }

    private func projectIndex(_ id: UUID) -> Int? {
        projects.firstIndex { $0.id == id }
    }

    // Applies `mutator` to the in-memory project at `id` and immediately persists it to disk.
    private func mutateProject(_ id: UUID, mutator: (inout Project) -> Void) {
        guard let index = projectIndex(id) else { return }
        mutator(&projects[index])
        save(projects[index])
        DispatchQueue.main.async {
            self.objectWillChange.send()
        }
    }

    // Replaces the in-memory project copy and persists it. Use `mutateProject` for targeted field changes.
    private func updateProject(_ project: Project) {
        if let index = projectIndex(project.id) {
            DispatchQueue.main.async {
                self.projects[index] = project
                self.save(project)
            }
        }
    }

    private func rebuildRootSortOrders(_ project: inout Project) {
        // Folders and blobs maintain independent sort sequences
        let sortedFolders = project.folders.sorted { $0.sortOrder < $1.sortOrder }
        for (index, folder) in sortedFolders.enumerated() {
            if let i = project.folders.firstIndex(where: { $0.id == folder.id }) {
                project.folders[i].sortOrder = index
            }
        }

        let sortedBlobs = project.blobs
            .filter { $0.folderID == nil }
            .sorted { $0.sortOrder < $1.sortOrder }
        for (index, blob) in sortedBlobs.enumerated() {
            if let i = project.blobs.firstIndex(where: { $0.id == blob.id }) {
                project.blobs[i].sortOrder = index
            }
        }
    }

    private func rebuildFolderSortOrders(_ project: inout Project, folderID: UUID) {
        let blobs = project.blobs
            .filter { $0.folderID == folderID }
            .sorted { $0.sortOrder < $1.sortOrder }

        for (index, blob) in blobs.enumerated() {
            if let blobIndex = project.blobs.firstIndex(where: { $0.id == blob.id }) {
                project.blobs[blobIndex].sortOrder = index
            }
        }
    }
}

// MARK: - BlobPrinter

@available(macOS 13, *)
private final class BlobPrinter: NSObject, WKNavigationDelegate {
    private let webView: WKWebView
    private let jobTitle: String
    private static var active: BlobPrinter? // retained here to prevent deallocation before the print sheet closes

    init(jobTitle: String) {
        self.jobTitle = jobTitle
        // Letter-sized frame so layout approximates the printed page
        self.webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 816, height: 1056))
        super.init()
        self.webView.navigationDelegate = self
    }

    static func start(html: String, jobTitle: String) {
        let printer = BlobPrinter(jobTitle: jobTitle)
        active = printer
        printer.webView.loadHTMLString(html, baseURL: nil)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let window = NSApplication.shared.keyWindow else {
            Self.active = nil
            return
        }
        let op = webView.printOperation(with: .shared)
        op.jobTitle = jobTitle
        op.runModal(for: window, delegate: self,
                    didRun: #selector(printDidRun(_:success:contextInfo:)),
                    contextInfo: nil)
    }

    @objc private func printDidRun(_ op: NSPrintOperation, success: Bool,
                                   contextInfo: UnsafeMutableRawPointer?) {
        Self.active = nil
    }
}
