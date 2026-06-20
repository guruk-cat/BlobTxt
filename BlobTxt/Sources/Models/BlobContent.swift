import Foundation

// The live, in-memory owner of one open blob's content, keyed in LifecycleStore by symlink-resolved path. Surfaces (the main editor and the mini view) bind to this instead of reading and writing disk on their own, so the same blob shows the same content everywhere. `revision` is bumped on every committed change so a surface can tell it is showing stale content; `isDirty` is whether the in-memory body differs from disk.
// This type is also the home of the YAML front-matter format helpers, used both here (to split a file on load) and by ProjectStore (to write one back).
final class BlobContent: ObservableObject {
    let url: URL

    @Published var body: String
    @Published var metadata: BlobMetadata

    private(set) var revision: Int = 0
    private(set) var isDirty: Bool = false

    // Reads the file once, splitting front matter from body. An unreadable file yields empty content rather than failing, matching the editor's "open it blank" behavior.
    init(url: URL) {
        self.url = url
        if let raw = try? String(contentsOf: url, encoding: .utf8) {
            self.body = BlobContent.stripFrontMatter(from: raw)
            self.metadata = BlobContent.parseFrontMatter(from: raw)
        } else {
            self.body = ""
            self.metadata = BlobMetadata()
        }
    }

    // MARK: - Edits and persistence

    // A surface commits the editor's current text. No-op when unchanged so an idle save doesn't churn the revision or mark the document dirty.
    func updateBody(_ newBody: String) {
        guard newBody != body else { return }
        body = newBody
        revision += 1
        isDirty = true
    }

    // The Metadata panel commits edited front matter.
    func updateMetadata(_ newMetadata: BlobMetadata) {
        guard newMetadata != metadata else { return }
        metadata = newMetadata
        revision += 1
        isDirty = true
    }

    // The single writer for this blob: serializes the in-memory metadata ahead of the body and writes the file. Both surfaces and the panel persist through here, so there is never more than one writer racing on the same file.
    func save() {
        guard isDirty else { return }
        let output: String
        if let fm = BlobContent.serializeFrontMatter(metadata) {
            output = fm + "\n" + body
        } else {
            output = body
        }
        do {
            try output.write(to: url, atomically: true, encoding: .utf8)
            isDirty = false
        } catch {
            print("[BlobContent] Failed to save: \(error)")
        }
    }

    // MARK: - Front-matter format helpers

    // Returns `content` with its leading YAML front matter block removed.
    // Front matter is a block that begins and ends with a line containing only `---`.
    // If no front matter is detected, the original string is returned unchanged.
    static func stripFrontMatter(from content: String) -> String {
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
    static func parseFrontMatter(from content: String) -> BlobMetadata {
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
    static func serializeFrontMatter(_ metadata: BlobMetadata) -> String? {
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
}
