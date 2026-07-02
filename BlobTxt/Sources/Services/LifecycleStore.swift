import Foundation

// The registry of open blobs. A surface acquires a BlobContent when it mounts and releases it when it unmounts; the store keeps one instance per blob (keyed by symlink-resolved path) and reference-counts the surfaces holding it. When the last surface releases, the instance is evicted so a later open re-reads disk.
// Session-scoped and not persisted. Also holds the per-blob scroll cache and folded-heading cache; view state rather than content, so they live here rather than on BlobContent; both survive eviction so reopening a blob within the session restores its scroll and folds.
final class LifecycleStore {
    static let shared = LifecycleStore()
    private init() {}

    private var contents: [String: BlobContent] = [:]
    private var refcounts: [String: Int] = [:]
    private var scroll: [String: Int] = [:]
    private var folds: [String: [String]] = [:]

    private func key(_ url: URL) -> String { url.resolvingSymlinksInPath().path }

    // Returns the open BlobContent for `url`, creating it (reading disk) on first acquire, and records one more holder.
    func acquire(_ url: URL) -> BlobContent {
        let k = key(url)
        let content = contents[k] ?? {
            let fresh = BlobContent(url: url)
            contents[k] = fresh
            return fresh
        }()
        refcounts[k, default: 0] += 1
        return content
    }

    // Drops one holder; once none remain, flushes any unsaved content to disk and evicts. The scroll cache is left in place so a reopen restores position.
    func release(_ url: URL) {
        let k = key(url)
        guard let count = refcounts[k] else { return }
        if count <= 1 {
            contents[k]?.save()
            refcounts[k] = nil
            contents[k] = nil
        } else {
            refcounts[k] = count - 1
        }
    }

    // Re-reads any open blob whose file changed on disk (an external edit) and tells its surfaces to reconcile, reusing the same notification a cross-surface save fires. Dirty blobs are left alone. Called from the project's FSEvents watcher.
    func syncOpenBlobs() {
        for (_, content) in contents where content.reloadIfChangedExternally() {
            NotificationCenter.default.post(name: .blobContentDidSave, object: content.url)
        }
    }

    // MARK: - Scroll cache

    func scrollPosition(for url: URL) -> Int {
        scroll[key(url)] ?? 0
    }

    func setScrollPosition(_ value: Int, for url: URL) {
        scroll[key(url)] = value
    }

    // MARK: - Fold cache

    // Folded-heading slugs per blob, session-scoped like the scroll cache.
    func foldedHeadings(for url: URL) -> [String] {
        folds[key(url)] ?? []
    }

    func setFoldedHeadings(_ slugs: [String], for url: URL) {
        folds[key(url)] = slugs
    }
}
