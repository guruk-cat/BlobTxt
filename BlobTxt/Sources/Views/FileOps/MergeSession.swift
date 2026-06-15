import Foundation

// The state of one Merge Blobs flow, owned by `MergeBlobsPanel` so it survives stage changes.
// For now it holds only the ordered selection; later stages add heading config, file name, and
// metadata here.
final class MergeSession: ObservableObject {
    // The chosen blobs, in merge order. Identity is the file URL, so a blob can appear at most once.
    @Published var selected: [URL] = []

    func contains(_ url: URL) -> Bool { selected.contains(url) }

    // Inserts a not-yet-selected blob at `index` (clamped). Adding an already-present blob is a no-op.
    func insert(_ url: URL, at index: Int) {
        guard !selected.contains(url) else { return }
        selected.insert(url, at: min(max(index, 0), selected.count))
    }

    func remove(_ url: URL) {
        selected.removeAll { $0 == url }
    }

    // Moves an already-present blob to `index`, expressed against the list with the blob removed.
    func reorder(_ url: URL, to index: Int) {
        guard selected.contains(url) else { return }
        var rest = selected.filter { $0 != url }
        rest.insert(url, at: min(max(index, 0), rest.count))
        selected = rest
    }

    // The blob's name without its `.md` extension, for display.
    static func displayName(for url: URL) -> String {
        url.deletingPathExtension().lastPathComponent
    }
}
