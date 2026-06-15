import Foundation

// Per-blob heading adjustments for the merge, keyed by the blob's URL.
struct BlobHeadingConfig: Equatable {
    // Shift this blob's headings down by this many levels (H1 -> H2 -> …), clamped to H6 on apply.
    var demoteBy: Int = 0
    // For a blob that has no headings of its own, optionally synthesize one to prepend.
    var addHeading: Bool = false
    var addedHeadingText: String = ""
    var addedHeadingLevel: Int = 1
}

// Adjustments applied across every blob in the merge.
struct MergeWideHeadingConfig: Equatable {
    // Shift every heading down by this many levels, on top of any per-blob demotion.
    var demoteAllBy: Int = 0
    // Prepend a nested number (1., 1.1., 1.1.1., …) to each heading.
    var renumber: Bool = false
    // Include H1 in the numbering hierarchy. Off by default, so numbering starts at H2 = "1.".
    var numberH1: Bool = false
}

// The state of one Merge Blobs flow, owned by `MergeBlobsPanel` so it survives stage changes: the
// ordered selection, the heading adjustments, and the final stage's file name and metadata.
final class MergeSession: ObservableObject {
    // The chosen blobs, in merge order. Identity is the file URL, so a blob can appear at most once.
    @Published var selected: [URL] = []

    // Heading adjustments. Per-blob config is sparse: a missing entry means "no adjustment".
    @Published var blobConfigs: [URL: BlobHeadingConfig] = [:]
    @Published var headingConfig = MergeWideHeadingConfig()

    // The final stage's inputs: the merged file's base name (no extension) and its front-matter metadata.
    @Published var fileName = ""
    @Published var metadata = BlobMetadata()

    func blobConfig(for url: URL) -> BlobHeadingConfig { blobConfigs[url] ?? BlobHeadingConfig() }
    func setBlobConfig(_ config: BlobHeadingConfig, for url: URL) { blobConfigs[url] = config }

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
