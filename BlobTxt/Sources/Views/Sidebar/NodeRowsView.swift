import SwiftUI

// Renders a list of sibling nodes at a given depth, recursing into expanded folders.
struct NodeRowsView: View {
    @EnvironmentObject var appColors: AppColors

    let nodes: [FileNode]
    let depth: Int
    @ObservedObject var model: NavigatorModel
    @ObservedObject var git: GitTracker
    let trackingMode: TrackingMode
    let activeEditorURL: URL?
    let renamingURL: URL?
    @Binding var renameDraft: String
    let glowingFolder: URL?
    let dropTargetFolder: URL?
    let draggedURL: URL?
    let onOpen: (URL) -> Void
    let onToggle: (FileNode) -> Void
    let onStartRename: (FileNode) -> Void
    let onCommitRename: (FileNode) -> Void
    let onCancelRename: () -> Void
    let onDelete: (FileNode) -> Void
    // Drag gesture callbacks, tagged with the dragged node. `changed` carries the cursor location.
    let onDragChanged: (FileNode, CGPoint) -> Void
    let onDragEnded: (FileNode) -> Void

    var body: some View {
        ForEach(nodes) { node in
            // The row highlights when it lies inside the currently targeted folder, so an entire folder's contents glow as one box.
            FileRowView(
                node: node,
                depth: depth,
                indicator: indicator(for: node),
                isExpanded: model.isExpanded(node),
                isSelected: !node.isDirectory && activeEditorURL == node.url,
                isContext: node.isDirectory && sameFile(model.contextDir, node.url),
                isGlowing: node.isDirectory && sameFile(glowingFolder, node.url),
                isDropHighlighted: isInTargetedFolder(node.url),
                isDragged: sameFile(draggedURL, node.url),
                isRenaming: sameFile(renamingURL, node.url),
                renameDraft: $renameDraft,
                onTap: {
                    if node.isDirectory { onToggle(node) } else { onOpen(node.url) }
                },
                onStartRename: { onStartRename(node) },
                onCommitRename: { onCommitRename(node) },
                onCancelRename: onCancelRename,
                onDelete: { onDelete(node) },
                onDragChanged: { location in onDragChanged(node, location) },
                onDragEnded: { onDragEnded(node) }
            )

            if node.isDirectory && model.isExpanded(node) {
                NodeRowsView(
                    nodes: node.children,
                    depth: depth + 1,
                    model: model,
                    git: git,
                    trackingMode: trackingMode,
                    activeEditorURL: activeEditorURL,
                    renamingURL: renamingURL,
                    renameDraft: $renameDraft,
                    glowingFolder: glowingFolder,
                    dropTargetFolder: dropTargetFolder,
                    draggedURL: draggedURL,
                    onOpen: onOpen,
                    onToggle: onToggle,
                    onStartRename: onStartRename,
                    onCommitRename: onCommitRename,
                    onCancelRename: onCancelRename,
                    onDelete: onDelete,
                    onDragChanged: onDragChanged,
                    onDragEnded: onDragEnded
                )
            }
        }
        .animation(.spring(response: 0.28, dampingFraction: 0.9), value: nodes.map(\.id))
    }

    // True when `url` is the currently targeted folder or lives anywhere inside it. A nil target (project root or no drag) highlights nothing, so dropping to root stays unhighlighted.
    private func isInTargetedFolder(_ url: URL) -> Bool {
        guard let target = dropTargetFolder else { return false }
        return sameFile(target, url) || isWithin(url, folder: target)
    }

    // The trailing indicator for a row, resolved for the active mode. Regular mode shows nothing.
    private func indicator(for node: FileNode) -> RowIndicator {
        let path = node.url.resolvingSymlinksInPath().path
        switch trackingMode {
        case .regular:
            return .none

        case .git:
            if node.isDirectory {
                guard let kind = git.aggregateKind(forFolderAt: path) else { return .none }
                return .dot(gitColor(kind))
            }
            let badges = git.badges(forFileAt: path)
                .map { RowBadge(letter: $0.letter, color: gitColor($0.kind)) }
            return badges.isEmpty ? .none : .badges(badges)
        }
    }

    private func gitColor(_ kind: GitStatusKind) -> Color {
        switch kind {
        case .untracked: return appColors.gitUntracked
        case .unstaged:  return appColors.gitUnstaged
        case .staged:    return appColors.gitStaged
        }
    }
}
