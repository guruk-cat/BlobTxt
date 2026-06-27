import Foundation

// The live, in-memory owner of one open blob's content, keyed in LifecycleStore by symlink-resolved path. Surfaces (the main editor and the mini view) bind to this instead of reading and writing disk on their own, so the same blob shows the same content everywhere. `revision` is bumped on every committed change so a surface can tell it is showing stale content; `isDirty` is whether the in-memory body differs from disk.
final class BlobContent: ObservableObject {
    let url: URL

    @Published var body: String

    private(set) var revision: Int = 0
    private(set) var isDirty: Bool = false

    // Reads the whole file once. The entire file is the body — any YAML front matter is ordinary editable content. An unreadable file yields empty content rather than failing, matching the editor's "open it blank" behavior.
    init(url: URL) {
        self.url = url
        self.body = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
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
        } catch {
            print("[BlobContent] Failed to save: \(error)")
        }
    }
}
