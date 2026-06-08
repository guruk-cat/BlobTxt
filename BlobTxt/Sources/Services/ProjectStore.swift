import SwiftUI
import WebKit

class ProjectStore: ObservableObject {
    @Published var currentProject: Project? = nil
    @Published var activeEditorBlobURL: URL? = nil
    var blobScrollPositions: [URL: Int] = [:]

    private let fileManager = FileManager.default

    init() {
        if let path = UserDefaults.standard.string(forKey: "lastProjectPath") {
            let url = URL(fileURLWithPath: path)
            var isDir: ObjCBool = false
            if fileManager.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                openProject(at: url)
            }
        }
    }

    // MARK: - Project

    // Opens a directory as the active project, creating `.blobtxt` if absent.
    // Saves to the recent-projects list (max 10) and persists `lastProjectPath` for restore on next launch.
    func openProject(at directoryURL: URL) {
        let blobtxtURL = directoryURL.appendingPathComponent(".blobtxt")
        let name: String
        if let existing = try? String(contentsOf: blobtxtURL, encoding: .utf8),
           let nameLine = existing.components(separatedBy: "\n").first(where: { $0.hasPrefix("name:") }) {
            name = String(nameLine.dropFirst(5)).trimmingCharacters(in: .whitespaces)
        } else {
            name = directoryURL.lastPathComponent
            try? "name: \(directoryURL.lastPathComponent)\n".write(to: blobtxtURL, atomically: true, encoding: .utf8)
        }

        var recent = UserDefaults.standard.stringArray(forKey: "recentProjectPaths") ?? []
        recent.removeAll { $0 == directoryURL.path }
        recent.insert(directoryURL.path, at: 0)
        if recent.count > 10 { recent = Array(recent.prefix(10)) }
        UserDefaults.standard.set(recent, forKey: "recentProjectPaths")
        UserDefaults.standard.set(directoryURL.path, forKey: "lastProjectPath")

        DispatchQueue.main.async {
            self.currentProject = Project(url: directoryURL, name: name)
        }
    }

    // Returns up to 10 most recently opened project directories that still exist on disk.
    func recentProjectURLs() -> [URL] {
        (UserDefaults.standard.stringArray(forKey: "recentProjectPaths") ?? []).compactMap { path in
            var isDir: ObjCBool = false
            guard fileManager.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { return nil }
            return URL(fileURLWithPath: path)
        }
    }

    // Writes an updated name to `.blobtxt` and refreshes `currentProject`.
    func renameProject(to name: String) {
        guard let project = currentProject else { return }
        try? "name: \(name)\n".write(to: project.url.appendingPathComponent(".blobtxt"), atomically: true, encoding: .utf8)
        DispatchQueue.main.async { self.currentProject = Project(url: project.url, name: name) }
    }

    // MARK: - Directory reads

    // Lists `.md` blobs and subdirectories in `url`, alphabetically sorted. Hidden files excluded.
    func contentsOfDirectory(url: URL) -> (blobs: [Blob], folders: [URL]) {
        guard let items = try? fileManager.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ) else { return ([], []) }
        var blobs: [Blob] = []
        var folders: [URL] = []
        for item in items.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let isDir = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            if isDir {
                folders.append(item)
            } else if item.pathExtension == "md" {
                blobs.append(Blob(url: item, displayName: item.deletingPathExtension().lastPathComponent))
            }
        }
        return (blobs, folders)
    }

    // MARK: - Blob CRUD

    // Creates a new empty `.md` file in `directoryURL`, choosing a non-conflicting "Untitled N" name.
    @discardableResult
    func createBlob(in directoryURL: URL) -> Blob {
        var name = "Untitled"
        var url = directoryURL.appendingPathComponent(name + ".md")
        var counter = 1
        while fileManager.fileExists(atPath: url.path) {
            name = "Untitled \(counter)"
            url = directoryURL.appendingPathComponent(name + ".md")
            counter += 1
        }
        fileManager.createFile(atPath: url.path, contents: nil)
        return Blob(url: url, displayName: name)
    }

    func deleteBlob(at url: URL) {
        try? fileManager.removeItem(at: url)
    }

    // Renames the blob file to `name + ".md"` within the same directory. Returns the new URL.
    @discardableResult
    func renameBlob(at url: URL, to name: String) -> URL {
        let safe = name
            .components(separatedBy: CharacterSet(charactersIn: "/\\:*?\"<>|"))
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let newURL = url.deletingLastPathComponent().appendingPathComponent((safe.isEmpty ? "Untitled" : safe) + ".md")
        guard newURL != url else { return url }
        try? fileManager.moveItem(at: url, to: newURL)
        return fileManager.fileExists(atPath: newURL.path) ? newURL : url
    }

    // Moves a blob file into `directoryURL`. Returns the new URL.
    @discardableResult
    func moveBlob(at url: URL, to directoryURL: URL) -> URL {
        let dest = directoryURL.appendingPathComponent(url.lastPathComponent)
        try? fileManager.moveItem(at: url, to: dest)
        return fileManager.fileExists(atPath: dest.path) ? dest : url
    }

    // MARK: - Folder CRUD

    @discardableResult
    func createFolder(in parentURL: URL, name: String) -> URL {
        var folderName = name
        var url = parentURL.appendingPathComponent(folderName)
        var counter = 1
        while fileManager.fileExists(atPath: url.path) {
            folderName = "\(name) \(counter)"
            url = parentURL.appendingPathComponent(folderName)
            counter += 1
        }
        try? fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func deleteFolder(at url: URL) {
        try? fileManager.removeItem(at: url)
    }

    @discardableResult
    func renameFolder(at url: URL, to name: String) -> URL {
        let newURL = url.deletingLastPathComponent().appendingPathComponent(name)
        guard newURL != url else { return url }
        try? fileManager.moveItem(at: url, to: newURL)
        return fileManager.fileExists(atPath: newURL.path) ? newURL : url
    }

    // MARK: - Blob Content I/O

    // Returns the Markdown body of the file at `url`, with YAML front matter stripped.
    func loadBlobContent(at url: URL) -> String? {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return splitFrontMatter(content).body
    }

    // Writes Markdown body to `url`, re-prepending any existing YAML front matter verbatim.
    func saveBlobContent(_ markdown: String, at url: URL) {
        var content = markdown
        if let existing = try? String(contentsOf: url, encoding: .utf8) {
            let fm = splitFrontMatter(existing).frontMatter
            if !fm.isEmpty { content = fm + markdown }
        }
        try? content.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - Blob Excerpt

    struct BlobExcerpt {
        var title: String?
        var body: String?
        var bodyAttributed: AttributedString?
    }

    // Returns a structured excerpt from the blob's Markdown content.
    // Title = text of the first `# ` heading. Body = first non-heading paragraph of plain text.
    func loadBlobExcerpt(at url: URL) -> BlobExcerpt {
        guard let body = loadBlobContent(at: url) else { return BlobExcerpt() }
        let lines = body.components(separatedBy: "\n")
        var title: String? = nil
        var bodyLines: [String] = []
        for line in lines {
            if title == nil, let (level, text) = parseMarkdownHeading(line), level == 1 {
                title = text
            } else {
                bodyLines.append(line)
            }
        }
        var collected: [String] = []
        var inParagraph = false
        for line in bodyLines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { if inParagraph { break }; continue }
            if trimmed.hasPrefix("#") { continue }
            if trimmed.range(of: #"^\[\^[^\]]+\]:"#, options: .regularExpression) != nil { continue }
            inParagraph = true
            collected.append(stripMarkdownSyntax(line))
        }
        let rawBody = collected.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        let bodyText: String? = rawBody.isEmpty ? nil : rawBody
        return BlobExcerpt(title: title, body: bodyText, bodyAttributed: bodyText.map { AttributedString($0) })
    }

    // MARK: - Search

    struct SearchResult: Identifiable {
        var id: URL { blob.url }
        var blob: Blob
        var matchCount: Int
        var excerpt: BlobExcerpt
    }

    struct SnippetMatch: Identifiable {
        var id: Int { occurrenceIndex }
        var occurrenceIndex: Int
        var snippet: String
    }

    // Searches all `.md` blobs directly inside `directoryURL` (not recursive) for `query`.
    func searchBlobs(in directoryURL: URL, query: String) -> [SearchResult] {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        let (blobs, _) = contentsOfDirectory(url: directoryURL)
        let q = query.lowercased()
        return blobs.compactMap { blob in
            guard let text = loadBlobPlainText(at: blob.url, maxWords: .max) else { return nil }
            let count = countOccurrences(of: q, in: text.lowercased())
            guard count > 0 else { return nil }
            return SearchResult(blob: blob, matchCount: count, excerpt: loadBlobExcerpt(at: blob.url))
        }
    }

    // Extracts snippet matches (surrounding context) for each occurrence of `query` in a blob.
    func searchSnippets(at url: URL, query: String, snippetRadius: Int = 60) -> [SnippetMatch] {
        guard !query.isEmpty, let text = loadBlobPlainText(at: url, maxWords: .max) else { return [] }
        var matches: [SnippetMatch] = []
        var searchRange = text.startIndex..<text.endIndex
        var index = 0
        while let range = text.range(of: query, options: .caseInsensitive, range: searchRange) {
            let textLen = text.count
            let matchPos = text.distance(from: text.startIndex, to: range.lowerBound)
            let matchEnd = text.distance(from: text.startIndex, to: range.upperBound)
            let s0 = max(0, matchPos - snippetRadius), s1 = min(textLen, matchEnd + snippetRadius)
            let snippetStart = text.index(text.startIndex, offsetBy: s0)
            let snippetEnd = text.index(text.startIndex, offsetBy: s1)
            var snippet = String(text[snippetStart..<snippetEnd])
            if s0 > 0 { snippet = "…" + snippet }
            if s1 < textLen { snippet += "…" }
            matches.append(SnippetMatch(occurrenceIndex: index, snippet: snippet))
            searchRange = range.upperBound..<text.endIndex
            index += 1
        }
        return matches
    }

    // Replaces all case-insensitive occurrences of `find` with `replace` in the given blob files.
    func replaceAllInBlobs(at urls: [URL], find: String, replace: String) {
        guard !find.isEmpty else { return }
        for url in urls {
            guard let body = loadBlobContent(at: url) else { continue }
            let modified = body.replacingOccurrences(of: find, with: replace, options: .caseInsensitive)
            guard modified != body else { continue }
            saveBlobContent(modified, at: url)
        }
    }

    private func countOccurrences(of query: String, in text: String) -> Int {
        var count = 0; var range = text.startIndex..<text.endIndex
        while let found = text.range(of: query, range: range) { count += 1; range = found.upperBound..<text.endIndex }
        return count
    }

    // MARK: - Blob Outline

    struct BlobHeading {
        var level: Int
        var text: String
    }

    // Returns every heading (levels 1–3) from the blob's Markdown, in document order.
    func loadBlobHeadings(at url: URL) -> [BlobHeading] {
        guard let body = loadBlobContent(at: url) else { return [] }
        return body.components(separatedBy: "\n").compactMap { parseMarkdownHeading($0).map { BlobHeading(level: $0.level, text: $0.text) } }
    }

    // Returns plain text from a blob's Markdown body with Markdown syntax stripped.
    // Pass maxWords: .max to get the full text.
    func loadBlobPlainText(at url: URL, maxWords: Int = 30) -> String? {
        guard let body = loadBlobContent(at: url) else { return nil }
        let stripped = stripMarkdownSyntax(body).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !stripped.isEmpty else { return nil }
        if maxWords == .max { return stripped }
        return stripped.split(separator: " ", omittingEmptySubsequences: true).prefix(maxWords).joined(separator: " ")
    }

    // Counts words in the blob's Markdown body, excluding footnote definition lines.
    func loadBlobWordCount(at url: URL) -> Int {
        guard let body = loadBlobContent(at: url) else { return 0 }
        let stripped = stripMarkdownSyntax(body).trimmingCharacters(in: .whitespacesAndNewlines)
        return stripped.isEmpty ? 0 : stripped.split(separator: " ", omittingEmptySubsequences: true).count
    }

    // Generates an HTML fragment from the blob's Markdown content for use by the print pipeline.
    func loadBlobHTML(at url: URL) -> String? {
        guard let body = loadBlobContent(at: url) else { return nil }
        let html = MarkdownHTMLRenderer.render(body)
        return html.isEmpty ? nil : html
    }

    // MARK: - Print

    func printBlob(at url: URL) {
        guard let fragment = loadBlobHTML(at: url) else { return }
        let profileName = UserDefaults.standard.string(forKey: "printProfile") ?? "default"
        let css = loadPrintProfileCSS(profileName: profileName) ?? loadFirstAvailablePrintProfileCSS() ?? ""
        let excerpt = loadBlobExcerpt(at: url)
        let rawTitle: String
        if let h = excerpt.title { rawTitle = h }
        else if let b = excerpt.body { rawTitle = b.split(separator: " ", omittingEmptySubsequences: true).prefix(6).joined(separator: " ") }
        else { rawTitle = "Untitled" }
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
        if #available(macOS 13, *) { BlobPrinter.start(html: document, jobTitle: rawTitle) }
    }

    private func loadPrintProfileCSS(profileName: String) -> String? {
        guard let url = Bundle.main.url(forResource: profileName, withExtension: "css", subdirectory: "print-profiles") else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    private func loadFirstAvailablePrintProfileCSS() -> String? {
        guard let urls = Bundle.main.urls(forResourcesWithExtension: "css", subdirectory: "print-profiles"),
              let first = urls.first else { return nil }
        return try? String(contentsOf: first, encoding: .utf8)
    }

    // MARK: - Private Helpers

    private func splitFrontMatter(_ content: String) -> (frontMatter: String, body: String) {
        let lines = content.components(separatedBy: "\n")
        guard lines.first == "---" else { return ("", content) }
        guard let closeIndex = lines.dropFirst().firstIndex(of: "---") else { return ("", content) }
        let frontMatter = lines[0...closeIndex].joined(separator: "\n") + "\n"
        let body = lines[(closeIndex + 1)...].joined(separator: "\n")
        return (frontMatter, body)
    }

    private func parseMarkdownHeading(_ line: String) -> (level: Int, text: String)? {
        guard let regex = try? NSRegularExpression(pattern: #"^(#{1,3})\s+(.+)"#),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let hr = Range(match.range(at: 1), in: line),
              let tr = Range(match.range(at: 2), in: line) else { return nil }
        return (line[hr].count, String(line[tr]).trimmingCharacters(in: .whitespaces))
    }

    private func stripMarkdownSyntax(_ text: String) -> String {
        var s = text
        s = s.replacingOccurrences(of: #"^\[\^[^\]]+\]:.*$"#, with: "", options: [.regularExpression, .anchored])
        s = s.replacingOccurrences(of: #"\[\^[^\]]+\]"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"!\[[^\]]*\]\([^)]*\)"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\*{1,3}|_{1,3}"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"`[^`]*`"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"^#{1,6}\s+"#, with: "", options: [.regularExpression, .anchored])
        s = s.replacingOccurrences(of: #"^>\s?"#, with: "", options: [.regularExpression, .anchored])
        return s
    }
}

// MARK: - MarkdownHTMLRenderer

// Converts a Markdown string to an HTML fragment suitable for the print view.
// Handles block types (headings, paragraphs, blockquotes, bullet/ordered lists, code blocks,
// horizontal rules) and inline marks (bold, italic, inline code, links, images, footnote
// references). Footnote definitions are collected and emitted as a numbered `<ol>` at the end.
// The HTML structure mirrors what `renderNodeHTML` previously produced, so existing print
// profile CSS continues to apply without changes.
private struct MarkdownHTMLRenderer {

    static func render(_ markdown: String) -> String {
        let lines = markdown.components(separatedBy: "\n")
        var html = ""
        var footnoteDefinitions: [(label: String, body: String)] = []
        var i = 0
        while i < lines.count {
            let line = lines[i]
            if line.trimmingCharacters(in: .whitespaces).isEmpty { i += 1; continue }
            if let (label, body) = parseFootnoteDef(line) { footnoteDefinitions.append((label, body)); i += 1; continue }
            if let (level, text) = parseHeading(line) { html += "<h\(level)>\(inlineHTML(text))</h\(level)>\n"; i += 1; continue }
            if isHorizontalRule(line) { html += "<hr/>\n"; i += 1; continue }
            if line.hasPrefix("```") {
                var codeLines: [String] = []; i += 1
                while i < lines.count && !lines[i].hasPrefix("```") { codeLines.append(xmlEscape(lines[i])); i += 1 }
                html += "<pre><code>\(codeLines.joined(separator: "\n"))</code></pre>\n"; i += 1; continue
            }
            if line.hasPrefix(">") {
                var quoteLines: [String] = []
                while i < lines.count && lines[i].hasPrefix(">") {
                    quoteLines.append(String(lines[i].dropFirst()).trimmingCharacters(in: .init(charactersIn: " "))); i += 1
                }
                html += "<blockquote>\(quoteLines.map { "<p>\(inlineHTML($0))</p>" }.joined())</blockquote>\n"; continue
            }
            if isUnorderedListItem(line) {
                html += "<ul>\n"
                while i < lines.count && isUnorderedListItem(lines[i]) {
                    let text = lines[i].replacingOccurrences(of: #"^[-*+]\s+"#, with: "", options: .regularExpression)
                    html += "<li>\(inlineHTML(text))</li>\n"; i += 1
                }
                html += "</ul>\n"; continue
            }
            if isOrderedListItem(line) {
                html += "<ol>\n"
                while i < lines.count && isOrderedListItem(lines[i]) {
                    let text = lines[i].replacingOccurrences(of: #"^\d+\.\s+"#, with: "", options: .regularExpression)
                    html += "<li>\(inlineHTML(text))</li>\n"; i += 1
                }
                html += "</ol>\n"; continue
            }
            html += "<p>\(inlineHTML(line))</p>\n"; i += 1
        }
        if !footnoteDefinitions.isEmpty {
            html += "<ol class=\"footnotes\">\n"
            for fn in footnoteDefinitions {
                let label = xmlEscape(fn.label)
                html += "<li id=\"fn:\(label)\">\(inlineHTML(fn.body)) <a href=\"#ref:\(label)\">↑</a></li>\n"
            }
            html += "</ol>\n"
        }
        return html
    }

    private static func inlineHTML(_ text: String) -> String {
        var s = xmlEscape(text)
        s = replaceRegex(s, pattern: #"`([^`]+)`"#) { "<code>\($0[1])</code>" }
        s = replaceRegex(s, pattern: #"!\[([^\]]*)\]\(([^)]*)\)"#) { "<img src=\"\($0[2])\" alt=\"\($0[1])\"/>" }
        s = replaceRegex(s, pattern: #"\[([^\]]*)\]\(([^)]*)\)"#) { "<a href=\"\($0[2])\">\($0[1])</a>" }
        s = replaceRegex(s, pattern: #"\[\^([^\]]+)\]"#) { "<sup id=\"ref:\($0[1])\"><a href=\"#fn:\($0[1])\">\($0[1])</a></sup>" }
        s = replaceRegex(s, pattern: #"\*\*\*(.+?)\*\*\*|___(.+?)___"#) { "<strong><em>\($0[1].isEmpty ? $0[2] : $0[1])</em></strong>" }
        s = replaceRegex(s, pattern: #"\*\*(.+?)\*\*|__(.+?)__"#) { "<strong>\($0[1].isEmpty ? $0[2] : $0[1])</strong>" }
        s = replaceRegex(s, pattern: #"\*(.+?)\*|_(.+?)_"#) { "<em>\($0[1].isEmpty ? $0[2] : $0[1])</em>" }
        return s
    }

    private static func parseHeading(_ line: String) -> (Int, String)? {
        guard let m = try? NSRegularExpression(pattern: #"^(#{1,6})\s+(.*)"#)
            .firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let hr = Range(m.range(at: 1), in: line), let tr = Range(m.range(at: 2), in: line) else { return nil }
        return (line[hr].count, String(line[tr]))
    }

    private static func parseFootnoteDef(_ line: String) -> (String, String)? {
        guard let m = try? NSRegularExpression(pattern: #"^\[\^([^\]]+)\]:\s*(.*)"#)
            .firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let lr = Range(m.range(at: 1), in: line), let br = Range(m.range(at: 2), in: line) else { return nil }
        return (String(line[lr]), String(line[br]))
    }

    private static func isHorizontalRule(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces); return t == "---" || t == "***" || t == "___"
    }
    private static func isUnorderedListItem(_ line: String) -> Bool { line.range(of: #"^[-*+]\s+"#, options: .regularExpression) != nil }
    private static func isOrderedListItem(_ line: String) -> Bool { line.range(of: #"^\d+\.\s+"#, options: .regularExpression) != nil }

    private static func xmlEscape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func replaceRegex(_ input: String, pattern: String, builder: ([String]) -> String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return input }
        var result = input; var offset = 0
        for match in regex.matches(in: input, range: NSRange(input.startIndex..., in: input)) {
            var groups: [String] = []
            for g in 0..<match.numberOfRanges {
                groups.append(Range(match.range(at: g), in: input).map { String(input[$0]) } ?? "")
            }
            let replacement = builder(groups)
            let matchRange = Range(match.range, in: input)!
            let lo = result.index(result.startIndex, offsetBy: result.distance(from: input.startIndex, to: matchRange.lowerBound) + offset)
            let hi = result.index(result.startIndex, offsetBy: result.distance(from: input.startIndex, to: matchRange.upperBound) + offset)
            result.replaceSubrange(lo..<hi, with: replacement)
            offset += replacement.count - input.distance(from: matchRange.lowerBound, to: matchRange.upperBound)
        }
        return result
    }
}

// MARK: - BlobPrinter

@available(macOS 13, *)
private final class BlobPrinter: NSObject, WKNavigationDelegate {
    private let webView: WKWebView
    private let jobTitle: String
    private static var active: BlobPrinter?

    init(jobTitle: String) {
        self.jobTitle = jobTitle
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
        guard let window = NSApplication.shared.keyWindow else { Self.active = nil; return }
        let op = webView.printOperation(with: .shared)
        op.jobTitle = jobTitle
        op.runModal(for: window, delegate: self, didRun: #selector(printDidRun(_:success:contextInfo:)), contextInfo: nil)
    }

    @objc private func printDidRun(_ op: NSPrintOperation, success: Bool, contextInfo: UnsafeMutableRawPointer?) {
        Self.active = nil
    }
}
