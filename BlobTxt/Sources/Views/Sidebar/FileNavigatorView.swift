import SwiftUI

// Shared coordinate space for the navigator tree. Row frames are tracked in this space and the drag
// gesture reports its location in it, so cursor positions and row rects can be compared directly.
private let navCoordinateSpace = "navTree"

// Collects each row's frame (keyed by file URL) so an in-progress drag can hit-test which row the
// cursor is over. SwiftUI merges the per-row preferences up to the ScrollView.
private struct RowFrameKey: PreferenceKey {
    static var defaultValue: [URL: CGRect] = [:]
    static func reduce(value: inout [URL: CGRect], nextValue: () -> [URL: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

struct FileNavigatorView: View {
    @EnvironmentObject var store: ProjectStore
    @EnvironmentObject var appColors: AppColors
    @Binding var activeEditorURL: URL?

    @StateObject private var model = NavigatorModel()

    // Per-mode status providers, each refreshed only while its mode is active.
    // The mode selector reads and writes `store.trackingMode`
    @StateObject private var git = GitTracker()
    @StateObject private var blaze = BlazeTracker()

    // Inline rename state: the row currently being renamed, and its editable draft text.
    @State private var renamingURL: URL? = nil
    @State private var renameDraft: String = ""

    // The node awaiting delete confirmation, if any.
    @State private var pendingDelete: FileNode? = nil

    // Drag-and-drop state.
    //
    // We deliberately do NOT use SwiftUI's `.onDrag`/`.onDrop`: on macOS its drag image is an
    // OS-owned snapshot that gets orphaned when the list reorders itself on drop, leaving a ghost
    // blob hanging in the air. Instead a manual `DragGesture` drives everything, and the dragged
    // blob is drawn a plain SwiftUI overlay (`dragOverlay`). Clearing `draggedURL` erases
    // that overlay instantly on drop, so there is no OS image to linger.
    //
    // `draggedURL`/`draggedName` identify the item currently being dragged (nil = no drag), and
    // `draggedIsDirectory` records whether it is a folder (drives the overlay icon and the move path).
    // `dragLocation` is the cursor position (in `navCoordinateSpace`) where the overlay is drawn.
    // `itemFrames` are the tracked row rects used to hit-test which folder the cursor is over.
    // `dropTargetFolder` is that resolved folder (nil = project root); it drives the folder-scoped
    // highlight box. `dropInvalid` is set while a folder hovers itself or one of its descendants — an
    // illegal destination — so the drop is suppressed without falling back to a root move.
    // `glowingFolder` is the folder flashing the post-drop confirmation glow.
    @State private var draggedURL: URL? = nil
    @State private var draggedName: String = ""
    @State private var draggedIsDirectory: Bool = false
    @State private var dragLocation: CGPoint = .zero
    @State private var itemFrames: [URL: CGRect] = [:]
    @State private var dropTargetFolder: URL? = nil
    @State private var dropInvalid: Bool = false
    @State private var glowingFolder: URL? = nil

    // Outer panel margins.
    private let verticalMargin: CGFloat = 8
    private let horizontalMargin: CGFloat = 6

    var body: some View {
        Group {
            if let project = store.currentProject {
                content(project: project)
            } else {
                Color.clear
            }
        }
        .onChange(of: store.currentProject?.url) { newURL in
            if let newURL = newURL { model.activate(projectURL: newURL) }
            refreshTracking()
        }
        .onAppear {
            if let url = store.currentProject?.url { model.activate(projectURL: url) }
            refreshTracking()
        }
        .onDisappear { model.deactivate() }
        // Re-run the active mode's status when the mode switches, and on every tree reload (which also
        // fires when an external tool rewrites `.git/index` or `.blaze/marks.toml`).
        .onChange(of: store.trackingMode) { _ in refreshTracking() }
        .onChange(of: model.reloadCount) { _ in refreshTracking() }
        .confirmationDialog(
            pendingDelete.map { "Delete \"\($0.name)\"?" } ?? "",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingDelete
        ) { node in
            Button("Move to Trash", role: .destructive) { performDelete(node) }
            Button("Cancel", role: .cancel) {}
        } message: { node in
            Text(node.isDirectory
                 ? "The folder and everything in it will be moved to the Trash."
                 : "It will be moved to the Trash.")
        }
    }

    // Top-level layout.
    private func content(project: Project) -> some View {
        VStack(spacing: 0) {
            headerRow(project: project)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if model.rootNodes.isEmpty {
                        emptyState
                    } else {
                        NodeRowsView(
                            nodes: model.rootNodes,
                            depth: 0,
                            model: model,
                            git: git,
                            blaze: blaze,
                            trackingMode: store.trackingMode,
                            activeEditorURL: activeEditorURL,
                            renamingURL: renamingURL,
                            renameDraft: $renameDraft,
                            glowingFolder: glowingFolder,
                            dropTargetFolder: dropTargetFolder,
                            draggedURL: draggedURL,
                            onOpen: openBlob,
                            onToggle: toggleFolder,
                            onStartRename: startRename,
                            onCommitRename: commitRename,
                            onCancelRename: cancelRename,
                            onDelete: requestDelete,
                            onMark: performMark,
                            onBumpUp: performBumpUp,
                            onBumpDown: performBumpDown,
                            onDragChanged: dragChanged,
                            onDragEnded: dragEnded
                        )
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.top, 4)
                .contentShape(Rectangle())
            }
            // Track row frames and host the drag overlay in one shared coordinate space, so the
            // cursor location, the tracked rects, and the floating preview all agree.
            .coordinateSpace(name: navCoordinateSpace)
            .onPreferenceChange(RowFrameKey.self) { itemFrames = $0 }
            .overlay(dragOverlay)

            if store.trackingMode == .git && !git.isRepository {
                trackingNotice("Git has not been initialized.")
            } else if store.trackingMode == .blaze && !blaze.isInitialized {
                trackingNotice("Blaze has not been initialized.")
            }

            modeToggle
        }
        .padding(.vertical, verticalMargin)
        .padding(.horizontal, horizontalMargin)
    }

    // Refreshes the status provider for the active model.
    private func refreshTracking() {
        switch store.trackingMode {
        case .regular:
            break
        case .git:
            git.refresh(projectURL: store.currentProject?.url)
        case .blaze:
            blaze.refresh(projectURL: store.currentProject?.url,
                          abbreviations: store.markAbbreviations)
        }
    }

    private func trackingNotice(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundColor(appColors.textMuted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 6)
    }

    // MARK: - Blaze write actions

    // These shell out to the blaze CLI (via BlazeTracker), which re-reads marks.toml on completion.
    private func performMark(_ node: FileNode, _ markName: String) {
        blaze.applyMark(fileAt: node.url.resolvingSymlinksInPath().path, as: markName)
    }

    private func performBumpUp(_ node: FileNode) {
        blaze.bumpUp(fileAt: node.url.resolvingSymlinksInPath().path)
    }

    private func performBumpDown(_ node: FileNode) {
        blaze.bumpDown(fileAt: node.url.resolvingSymlinksInPath().path)
    }

    // MARK: - Row actions

    // Opening a blob or toggling a folder counts as "doing something else", so it cancels
    // any in-progress rename rather than leaving a stray text field behind.
    private func openBlob(_ url: URL) {
        cancelRename()
        activeEditorURL = url
    }

    private func toggleFolder(_ node: FileNode) {
        cancelRename()
        model.toggle(node)
    }

    // MARK: - Drag and drop

    // Called continuously while a blob row is dragged. The first call latches the dragged blob (its
    // row stays in place but is rendered invisibly — see `FileRowView`/`isDragged` — so the gesture's
    // owning view is never destroyed mid-drag). Each call moves the floating overlay to the cursor
    // and resolves which folder the cursor is hovering, via the tracked row frames.
    private func dragChanged(_ node: FileNode, _ location: CGPoint) {
        if draggedURL == nil {
            draggedURL = node.url
            draggedName = node.name
            draggedIsDirectory = node.isDirectory
        }
        guard sameFile(draggedURL, node.url) else { return }
        dragLocation = location

        // The row under the cursor (its frame is collapsed to zero while dragged, so the dragged
        // item never matches itself). No row → empty space → project root.
        let hitURL = itemFrames.first(where: { $0.value.contains(location) })?.key
        let candidate = hitURL
            .flatMap { model.node(matching: $0) }
            .map { model.dropDestination(for: $0) } ?? nil

        // A folder cannot be dropped into itself or any descendant. The dragged folder's own row is
        // collapsed and so never hit-tests, but its still-rendered children can, so guard explicitly.
        // When invalid we clear the highlight and flag the drop, rather than letting `candidate` fall
        // through to a root move.
        if node.isDirectory, let candidate = candidate,
           sameFile(candidate, node.url) || isWithin(candidate, folder: node.url) {
            dropInvalid = true
            dropTargetFolder = nil
        } else {
            dropInvalid = false
            dropTargetFolder = candidate
        }
    }

    // Called when the drag is released. Clears the drag overlay first (so nothing lingers), then
    // performs the move into the resolved folder (nil = project root). The model move no-ops when the
    // item already lives in that folder, and a folder move into itself/a descendant was already
    // rejected as `dropInvalid` during the drag.
    private func dragEnded(_ node: FileNode) {
        guard sameFile(draggedURL, node.url) else { clearDrag(); return }
        let target = dropTargetFolder
        let invalid = dropInvalid
        let dragged = node.url
        clearDrag()
        guard !invalid else { return }

        let newURL = node.isDirectory
            ? model.moveFolder(dragged, into: target, using: store)
            : model.moveBlob(dragged, into: target, using: store)
        guard let newURL = newURL else { return }

        // Keep the open editor pointed at the right file: directly if the moved item is the open blob,
        // or by rebasing the open blob's path onto the folder's new location when it lived inside the
        // moved folder.
        if let active = activeEditorURL {
            if sameFile(active, dragged) {
                activeEditorURL = newURL
            } else if node.isDirectory, isWithin(active, folder: dragged) {
                let oldBase = dragged.resolvingSymlinksInPath().path
                let relative = String(active.resolvingSymlinksInPath().path.dropFirst(oldBase.count + 1))
                activeEditorURL = newURL.appendingPathComponent(relative)
            }
        }

        if let projectURL = store.currentProject?.url {
            blaze.recordRename(from: dragged, to: newURL,
                               isDirectory: node.isDirectory, projectURL: projectURL)
        }
        if let target = target { triggerGlow(target) }
    }

    private func clearDrag() {
        draggedURL = nil
        draggedName = ""
        draggedIsDirectory = false
        dragLocation = .zero
        dropTargetFolder = nil
        dropInvalid = false
    }

    // The floating drag preview: a plain SwiftUI view following the cursor.
    @ViewBuilder
    private var dragOverlay: some View {
        if draggedURL != nil {
            HStack(spacing: 5) {
                Image(systemName: draggedIsDirectory ? "folder" : "doc.text")
                    .font(.system(size: 10))
                    .foregroundColor(appColors.textHeading)
                Text(draggedName)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .foregroundColor(appColors.textHeading)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(appColors.surface)
            .cornerRadius(5)
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(appColors.borderCard, lineWidth: 1))
            .frame(width: 160, alignment: .leading)
            .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
            .position(dragLocation)
            .allowsHitTesting(false)
        }
    }

    // Briefly flashes the confirmation glow on a folder that just received a dropped blob.
    // The glow start is deferred one runloop tick so it lands after the move's `reload()` has
    // re-sorted the rows. Otherwise the glow attaches to the destination at its pre-move slot and
    // then slides with the row to its new position. The wait is imperceptible.
    private func triggerGlow(_ folder: URL) {
        DispatchQueue.main.async {
            glowingFolder = folder
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                if sameFile(glowingFolder, folder) { glowingFolder = nil }
            }
        }
    }

    // MARK: - Rename / delete handlers

    private func startRename(_ node: FileNode) {
        renameDraft = node.name
        renamingURL = node.url
    }

    // Begins renaming a freshly created item, identified only by its URL.
    private func beginRename(url: URL) {
        renameDraft = url.pathExtension == "md"
            ? url.deletingPathExtension().lastPathComponent
            : url.lastPathComponent
        renamingURL = url
    }

    private func cancelRename() {
        renamingURL = nil
    }

    // Commits the new file name. No-ops on an empty or unchanged name. If the renamed blob is
    // the one open in the editor, the active URL is repointed so the editor stays in sync.
    private func commitRename(_ node: FileNode) {
        defer { renamingURL = nil }
        let trimmed = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != node.name else { return }
        let newURL = model.rename(node, to: trimmed, using: store)
        if let newURL = newURL, activeEditorURL == node.url {
            activeEditorURL = newURL
        }
        // Keep blaze's record in step. 
        // A folder rename moves every blob inside it, so pass `--dir` (via isDirectory) to update them all in one call.
        if let newURL = newURL, let projectURL = store.currentProject?.url {
            blaze.recordRename(from: node.url, to: newURL,
                               isDirectory: node.isDirectory, projectURL: projectURL)
        }
    }

    private func requestDelete(_ node: FileNode) {
        pendingDelete = node
    }

    // Performs the confirmed delete.
    private func performDelete(_ node: FileNode) {
        if let active = activeEditorURL,
           active == node.url || active.path.hasPrefix(node.url.path + "/") {
            activeEditorURL = nil
        }
        model.delete(node, using: store)
    }

    // MARK: - Header
    private func headerRow(project: Project) -> some View {
        HStack(spacing: 8) {
            Text(project.name.uppercased())
                .font(.system(size: 12, weight: .semibold))
                .tracking(0.5)
                .foregroundColor(appColors.textHeading)
            Spacer()
            HeaderIconButton(systemName: "folder.badge.plus") {
                if let url = model.createFolder(using: store) { beginRename(url: url) }
            }
            HeaderIconButton(systemName: "doc.badge.plus") {
                if let url = model.createBlob(using: store) { beginRename(url: url) }
            }
        }
        .padding(.horizontal, 6)
        .padding(.bottom, 4)
    }

    private var emptyState: some View {
        Text("No documents.")
            .font(.system(size: 12))
            .foregroundColor(appColors.textMuted)
            .padding(.horizontal, 6)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Mode toggle
    private var modeToggle: some View {
        GeometryReader { geo in
            let modes = TrackingMode.allCases
            let slotW = geo.size.width / CGFloat(modes.count)
            let h: CGFloat = 28
            let r: CGFloat = 7
            let selectedIdx = CGFloat(modes.firstIndex(of: store.trackingMode) ?? 0)

            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: r)
                    .fill(appColors.surfaceSunken)

                RoundedRectangle(cornerRadius: r)
                    .fill(appColors.textHeading.opacity(0.9))
                    .frame(width: slotW - 6, height: h - 6)
                    .offset(x: selectedIdx * slotW + 3)
                    .animation(.spring(response: 0.2, dampingFraction: 0.92), value: store.trackingMode)

                HStack(spacing: 0) {
                    ForEach(modes, id: \.self) { mode in
                        Button { store.setTrackingMode(mode) } label: {
                            Text(mode.label)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(
                                    store.trackingMode == mode ? appColors.surface
                                    : appColors.textResting
                                )
                                .frame(width: slotW, height: h)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: r))
        }
        .frame(height: 28)
        .padding(.top, 8)
    }
}

// Compares two file URLs by their resolved filesystem path. Needed because
// `contentsOfDirectory` returns directory URLs with a trailing slash and with symlinks
// resolved (e.g. /var → /private/var), so a freshly created item's URL won't be `==` to its
// tree representation even when they point at the same file.
private func sameFile(_ a: URL?, _ b: URL) -> Bool {
    guard let a = a else { return false }
    return a.resolvingSymlinksInPath().path == b.resolvingSymlinksInPath().path
}

// True if `url` lives anywhere inside `folder`. Resolves symlinks so the comparison survives the
// trailing-slash / `/var`→`/private/var` differences that `contentsOfDirectory` URLs carry.
private func isWithin(_ url: URL, folder: URL) -> Bool {
    let f = folder.resolvingSymlinksInPath().path
    let u = url.resolvingSymlinksInPath().path
    return u.hasPrefix(f + "/")
}

// MARK: - Row indicators

// The trailing status mark on a row, resolved to concrete colors so FileRowView only has to draw it.
// `.badges` is a file's letter badges (one for blaze, up to two for git); `.dot` is a folder's
// aggregate.
enum RowIndicator: Equatable {
    case none
    case badges([RowBadge])
    case dot(Color)
}

struct RowBadge: Hashable {
    let letter: String
    let color: Color
}

// What the blaze context-menu section needs for one blob: its current mark (nil = untracked) and
// whether a bump is possible in each direction. nil (the field on FileRowView) means "show no blaze
// menu" — i.e. not blaze mode, or is a folder.
struct BlazeRowInfo: Equatable {
    let currentMark: String?
    let canBumpUp: Bool
    let canBumpDown: Bool
}

// MARK: - Recursive tree rows

// Renders a list of sibling nodes at a given depth, recursing into expanded folders.
private struct NodeRowsView: View {
    @EnvironmentObject var appColors: AppColors

    let nodes: [FileNode]
    let depth: Int
    @ObservedObject var model: NavigatorModel
    @ObservedObject var git: GitTracker
    @ObservedObject var blaze: BlazeTracker
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
    // Blaze write actions, tagged with the node they act on.
    let onMark: (FileNode, String) -> Void
    let onBumpUp: (FileNode) -> Void
    let onBumpDown: (FileNode) -> Void
    // Drag gesture callbacks, tagged with the dragged node. `changed` carries the cursor location.
    let onDragChanged: (FileNode, CGPoint) -> Void
    let onDragEnded: (FileNode) -> Void

    var body: some View {
        // In blaze mode the blobs are reordered by mark (see `orderedNodes`); other modes keep the
        // model's order. Animating on the resulting id sequence glides rows when a mark changes.
        let ordered = orderedNodes
        ForEach(ordered) { node in
            // The row highlights when it lies inside the currently targeted folder, so an entire
            // folder's contents glow as one box.
            FileRowView(
                node: node,
                depth: depth,
                indicator: indicator(for: node),
                blazeMarkNames: blaze.markNames,
                blazeRowInfo: blazeRowInfo(for: node),
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
                onMark: { markName in onMark(node, markName) },
                onBumpUp: { onBumpUp(node) },
                onBumpDown: { onBumpDown(node) },
                onDragChanged: { location in onDragChanged(node, location) },
                onDragEnded: { onDragEnded(node) }
            )

            if node.isDirectory && model.isExpanded(node) {
                NodeRowsView(
                    nodes: node.children,
                    depth: depth + 1,
                    model: model,
                    git: git,
                    blaze: blaze,
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
                    onMark: onMark,
                    onBumpUp: onBumpUp,
                    onBumpDown: onBumpDown,
                    onDragChanged: onDragChanged,
                    onDragEnded: onDragEnded
                )
            }
        }
        .animation(.spring(response: 0.28, dampingFraction: 0.9), value: ordered.map(\.id))
    }

    // Display order for this sibling list. In blaze mode, folders stay pinned above in their normal
    // alphabetical order while blobs are reordered by mark; other modes use the model's order as-is.
    private var orderedNodes: [FileNode] {
        guard trackingMode == .blaze else { return nodes }
        let folders = nodes.filter { $0.isDirectory }
        let blobs = nodes.filter { !$0.isDirectory }
        return folders + blobs.sorted(by: blazeOrder)
    }

    // Blaze blob ordering: hierarchy marks first (most advanced on top), then flat marks grouped by
    // mark name, then unmarked. Ties within any group break alphabetically by blob name.
    private func blazeOrder(_ a: FileNode, _ b: FileNode) -> Bool {
        let ra = blazeRank(a), rb = blazeRank(b)
        if ra.tier != rb.tier { return ra.tier < rb.tier }
        switch ra.tier {
        case 0:  // hierarchy: higher fraction (more advanced) first
            if ra.fraction != rb.fraction { return ra.fraction > rb.fraction }
        case 1:  // flat: group by mark name, alphabetically
            if ra.markName != rb.markName {
                return ra.markName.localizedCaseInsensitiveCompare(rb.markName) == .orderedAscending
            }
        default:
            break
        }
        return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
    }

    // Sort key for a blob: its tier (0 hierarchy, 1 flat, 2 unmarked) plus the within-tier fields.
    private func blazeRank(_ node: FileNode) -> (tier: Int, fraction: Double, markName: String) {
        guard let mark = blaze.mark(forFileAt: node.url.resolvingSymlinksInPath().path) else {
            return (2, 0, "")
        }
        return mark.isHierarchy ? (0, mark.fraction, "") : (1, 0, mark.name)
    }

    // True when `url` is the currently targeted folder or lives anywhere inside it. A nil target
    // (project root or no drag) highlights nothing, so dropping to root stays unhighlighted.
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

        case .blaze:
            // Blaze marks files only; folders carry no indicator.
            guard !node.isDirectory, let mark = blaze.mark(forFileAt: path) else { return .none }
            let color = mark.isHierarchy
                ? appColors.blazeHierarchyColor(fraction: mark.fraction)
                : appColors.blazeFlat
            return .badges([RowBadge(letter: mark.abbreviation, color: color)])
        }
    }

    private func gitColor(_ kind: GitStatusKind) -> Color {
        switch kind {
        case .untracked: return appColors.gitUntracked
        case .unstaged:  return appColors.gitUnstaged
        case .staged:    return appColors.gitStaged
        }
    }

    // The blaze menu payload for a blob (nil for folders, or outside blaze mode, or when blaze is
    // not initialized).
    private func blazeRowInfo(for node: FileNode) -> BlazeRowInfo? {
        guard trackingMode == .blaze, !node.isDirectory, blaze.isInitialized else { return nil }
        let mark = blaze.mark(forFileAt: node.url.resolvingSymlinksInPath().path)
        return BlazeRowInfo(
            currentMark: mark?.name,
            canBumpUp: mark?.canBumpUp ?? false,
            canBumpDown: mark?.canBumpDown ?? false
        )
    }
}

// A single navigator row. 
// Background color indication is a single priority chain (see `rowBackground`).
// Folders additionally get a separate logic for drop confirmation.
private struct FileRowView: View {
    @EnvironmentObject var appColors: AppColors

    let node: FileNode
    let depth: Int
    let indicator: RowIndicator          // trailing status mark, resolved for the active mode
    let blazeMarkNames: [String]         // all marks, for the "Mark" submenu (blaze mode)
    let blazeRowInfo: BlazeRowInfo?      // blaze menu payload; nil hides the blaze menu section
    let isExpanded: Bool
    let isSelected: Bool        // blob is the one open in the editor
    let isContext: Bool         // folder is the current context directory
    let isGlowing: Bool         // folder just received a dropped blob
    let isDropHighlighted: Bool // row lies inside the folder a drag is hovering into
    let isDragged: Bool         // this blob is the one currently being dragged
    let isRenaming: Bool
    @Binding var renameDraft: String
    let onTap: () -> Void
    let onStartRename: () -> Void
    let onCommitRename: () -> Void
    let onCancelRename: () -> Void
    let onDelete: () -> Void
    // Blaze write actions (used only when `blazeRowInfo` is non-nil).
    let onMark: (String) -> Void
    let onBumpUp: () -> Void
    let onBumpDown: () -> Void
    // Manual drag gesture callbacks. `changed` reports the cursor location in `navCoordinateSpace`.
    let onDragChanged: (CGPoint) -> Void
    let onDragEnded: () -> Void

    @FocusState private var fieldFocused: Bool
    @State private var hovering = false

    private let indentStep: CGFloat = 12

    var body: some View {
        // Blobs and folders are both draggable. The gesture coexists with tap/contextMenu via
        // `simultaneousGesture` and a minimum distance so a click still registers as a tap (and a
        // folder still toggles). It is omitted while renaming so the text field keeps normal mouse
        // behavior.
        if !isRenaming {
            rowCore.simultaneousGesture(dragGesture)
        } else {
            rowCore
        }
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .named(navCoordinateSpace))
            .onChanged { onDragChanged($0.location) }
            .onEnded { _ in onDragEnded() }
    }

    // Reports this row's frame (in the shared coordinate space) so a drag can hit-test it.
    private var frameTracker: some View {
        GeometryReader { geo in
            Color.clear.preference(
                key: RowFrameKey.self,
                value: [node.url: geo.frame(in: .named(navCoordinateSpace))]
            )
        }
    }

    // The styled row content.
    private var rowCore: some View {
        HStack(spacing: 5) {
            leadingSymbol
            if isRenaming {
                renameField
            } else {
                Text(node.name)
                    .font(.system(size: 12))
                    .foregroundColor(appColors.textResting)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            trackingIndicator
        }
        .padding(.leading, 6 + CGFloat(depth) * indentStep)
        .padding(.trailing, 6)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Collapse (don't remove) the dragged row: keeping the view alive preserves the gesture that
        // owns `.onEnded`. Removing it would strand the drag state.
        .frame(height: isDragged ? 0 : nil)
        .opacity(isDragged ? 0 : 1)
        .clipped()
        .background(frameTracker)
        .background(rowBackground)
        .overlay {
            // Drop-confirmation glow, drawn above the background. Kept always-present (rather than
            // conditional) so its opacity can fade out smoothly; hit testing is disabled so it never
            // swallows row taps.
            RoundedRectangle(cornerRadius: 4)
                .fill(appColors.metaConfirmation)
                .opacity(isGlowing ? 0.3 : 0)
                .animation(.easeOut(duration: 0.45), value: isGlowing)
                .allowsHitTesting(false)
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { if !isRenaming { onTap() } }
        .contextMenu {
            Button("Rename", action: onStartRename)
            Button("Delete", role: .destructive, action: onDelete)
            blazeMenu
        }
    }

    // Blaze actions, shown only for a blob in blaze mode. 
    @ViewBuilder
    private var blazeMenu: some View {
        if let info = blazeRowInfo {
            Divider()
            if info.canBumpUp { Button("Bump Up", action: onBumpUp) }
            if info.canBumpDown { Button("Bump Down", action: onBumpDown) }
            Menu("Mark") {
                ForEach(blazeMarkNames, id: \.self) { name in
                    Button { onMark(name) } label: {
                        if name == info.currentMark {
                            Label(name, systemImage: "checkmark")
                        } else {
                            Text(name)
                        }
                    }
                }
            }
        }
    }

    // Single source of truth for the row's background tint. Order encodes priority.
    private var rowBackground: Color {
        if isDropHighlighted {
            return appColors.metaIndication.opacity(0.12)
        } else if isSelected {
            // return appColors.metaIndication.opacity(0.08)
            return appColors.surfaceRaised.opacity(0.5)
        } else if hovering {
            return appColors.surfaceRaised.opacity(0.25)
        } else if isContext {
            // return appColors.surfaceRaised.opacity(0.5)
            return .clear
        } else {
            return .clear
        }
    }

    // Inline text field shown while renaming. Enter commits; Escape cancels. Interacting with
    // another row cancels the rename from the parent (which clears `isRenaming`), so there is
    // deliberately no commit-on-focus-loss here.
    private var renameField: some View {
        TextField("", text: $renameDraft)
            .textFieldStyle(.plain)
            .font(.system(size: 12))
            .foregroundColor(appColors.textBody)
            .focused($fieldFocused)
            .onAppear { fieldFocused = true }
            .onSubmit(onCommitRename)
            .onExitCommand(perform: onCancelRename)
    }

    // Trailing tracking indicato. 
    // Both git and blaze feed the same `RowIndicator`; regular mode and "nothing to show" resolve to `.none`.
    @ViewBuilder
    private var trackingIndicator: some View {
        switch indicator {
        case .none:
            EmptyView()
        case .dot(let color):
            Circle()
                .fill(color)
                .frame(width: 5, height: 5)
        case .badges(let badges):
            HStack(spacing: 3) {
                ForEach(badges, id: \.self) { badge in
                    Text(badge.letter)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(badge.color)
                }
            }
        }
    }

    // Chevron for folders (rotates when expanded); fixed file icon for blobs.
    @ViewBuilder
    private var leadingSymbol: some View {
        if node.isDirectory {
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(appColors.textResting)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .frame(width: 12, alignment: .center)
        } else {
            Image(systemName: "doc.text")
                .font(.system(size: 10))
                .foregroundColor(isSelected ? appColors.metaIndication : appColors.textResting)
                .frame(width: 12, alignment: .center)
        }
    }
}

// Header action button
private struct HeaderIconButton: View {
    @EnvironmentObject var appColors: AppColors
    let systemName: String
    let action: () -> Void

    @State private var hovering = false
    @State private var glowing = false

    var body: some View {
        Button {
            action()
            glowing = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                withAnimation(.easeOut(duration: 0.3)) { glowing = false }
            }
        } label: {
            Image(systemName: systemName)
                .font(.system(size: 12))
                .foregroundColor(
                    glowing ? appColors.metaConfirmation
                    : hovering ? appColors.metaIndication
                    : appColors.textResting
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

#Preview {
    FileNavigatorView(activeEditorURL: .constant(nil))
        .environmentObject(ProjectStore())
        .environmentObject(AppColors.shared)
        .frame(width: 254)
}
