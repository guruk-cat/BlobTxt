import Foundation

// The live, in-memory owner of one open blob's content, keyed in LifecycleStore by symlink-resolved path. Surfaces (the main editor and the mini view) bind to this instead of reading and writing disk on their own, so the same blob shows the same content everywhere. `revision` is bumped on every committed change so a surface can tell it is showing stale content; `isDirty` is whether the in-memory body differs from disk.
final class BlobContent: ObservableObject {
    let url: URL

    @Published var body: String

    private(set) var revision: Int = 0
    private(set) var isDirty: Bool = false

    // The file's modification date as of the last read or write we performed. Used to tell an external edit apart from our own atomic write when the FSEvents watcher fires.
    private var lastKnownModDate: Date?

    // Reads the whole file once. The entire file is the body — any YAML front matter is ordinary editable content. An unreadable file yields empty content rather than failing, matching the editor's "open it blank" behavior.
    init(url: URL) {
        self.url = url
        self.body = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        lastKnownModDate = Self.modDate(of: url)
    }

    private static func modDate(of url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    // A surface commits the editor's current text. No-op when unchanged so an idle save doesn't churn the revision or mark the document dirty.
    func updateBody(_ newBody: String) {
        guard newBody != body else { return }
        body = newBody
        revision += 1
        isDirty = true
    }

    // The single writer for this blob: writes the in-memory body verbatim. Both surfaces persist through here, so there is never more than one writer racing on the same file.
    func save() {
        guard isDirty else { return }
        do {
            try body.write(to: url, atomically: true, encoding: .utf8)
            isDirty = false
            lastKnownModDate = Self.modDate(of: url)
        } catch {
            print("[BlobContent] Failed to save: \(error)")
        }
    }

    // Re-reads the file when it changed on disk since we last touched it (an external edit). Returns true if the body was actually replaced. Our own atomic write is a no-op here because save() records the resulting mod date. A dirty surface keeps its unsaved edits and lets the next save win (last-writer-wins).
    @discardableResult
    func reloadIfChangedExternally() -> Bool {
        guard !isDirty else { return false }
        let disk = Self.modDate(of: url)
        guard disk != lastKnownModDate else { return false }
        guard let fresh = try? String(contentsOf: url, encoding: .utf8), fresh != body else {
            lastKnownModDate = disk
            return false
        }
        body = fresh
        revision += 1
        lastKnownModDate = disk
        return true
    }
}
