import Foundation

// Describes a blob or folder that moved on disk (a rename or a drag-move), broadcast so any surface showing the moved blob (or one inside a moved folder) can follow it. `isDirectory` distinguishes a folder move, whose descendants must rebase, from a single file move.
struct BlobMoveInfo {
    let old: URL
    let new: URL
    let isDirectory: Bool
}

// Returns where `url` lands after `move`, or nil if the move does not affect it. A direct match returns the new path; a blob inside a moved folder rebases its relative path onto the folder's new location. Paths are symlink-resolved so the comparison survives the `/var`→`/private/var` and trailing-slash differences that directory URLs carry.
func repointedURL(_ url: URL, forMove move: BlobMoveInfo) -> URL? {
    let target = url.resolvingSymlinksInPath().path
    let oldBase = move.old.resolvingSymlinksInPath().path
    if target == oldBase { return move.new }
    if move.isDirectory, target.hasPrefix(oldBase + "/") {
        let relative = String(target.dropFirst(oldBase.count + 1))
        return move.new.appendingPathComponent(relative)
    }
    return nil
}

// True if `url` is the deleted item or lives inside a deleted folder.
func isAffected(_ url: URL, byDeletionOf deleted: URL) -> Bool {
    let u = url.resolvingSymlinksInPath().path
    let d = deleted.resolvingSymlinksInPath().path
    return u == d || u.hasPrefix(d + "/")
}
