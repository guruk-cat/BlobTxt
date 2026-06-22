import SwiftUI

// Shared coordinate space for the navigator tree. Row frames are tracked in this space and the drag gesture reports its location in it, so cursor positions and row rects can be compared directly.
let navCoordinateSpace = "navTree"

// Collects each row's frame (keyed by file URL) so an in-progress drag can hit-test which row the cursor is over. SwiftUI merges the per-row preferences up to the ScrollView.
struct RowFrameKey: PreferenceKey {
    static var defaultValue: [URL: CGRect] = [:]
    static func reduce(value: inout [URL: CGRect], nextValue: () -> [URL: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

struct FileNavigatorView: View {
    @EnvironmentObject var store: ProjectStore
    @EnvironmentObject var appColors: AppColors
    @Binding var activeEditorURL: URL?
    // Opening a row goes through this so the current blob is saved before the swap. The binding above is still used for repointing the open blob after a rename/move and clearing it on delete.
    let onRequestOpen: (URL) -> Void

    // Injected from ContentView; activation is driven there (see its declaration).
    @ObservedObject var model: NavigatorModel

    // Git status provider, refreshed only while git mode is active.
    @StateObject private var git = GitTracker()

    // Inline rename state: the row currently being renamed, and its editable draft text.
    @State private var renamingURL: URL? = nil
    @State private var renameDraft: String = ""

    // The node awaiting delete confirmation, if any.
    @State private var pendingDelete: FileNode? = nil

    // Drag-and-drop state.
    //
    // Deliberately not SwiftUI's `.onDrag`/`.onDrop`: on macOS its OS-owned drag image gets orphaned when the list reorders on drop, leaving a ghost blob in the air.
    // Instead a manual `DragGesture` drives everything and the preview is a plain SwiftUI overlay (`dragOverlay`); clearing `draggedURL` erases it instantly, so nothing lingers.
    //
    // `dropTargetFolder` (nil = project root) is the resolved drop folder, driving the highlight box.
    // `dropInvalid` suppresses the drop while a folder hovers itself or a descendant. `glowingFolder` is the folder flashing the post-drop confirmation glow.
    @State private var draggedURL: URL? = nil
    @State private var draggedName: String = ""
    @State private var draggedIsDirectory: Bool = false
    @State private var dragLocation: CGPoint = .zero       // cursor position, in navCoordinateSpace
    @State private var itemFrames: [URL: CGRect] = [:]     // tracked row rects, for hit-testing
    @State private var dropTargetFolder: URL? = nil
    @State private var dropInvalid: Bool = false
    @State private var glowingFolder: URL? = nil

    // Explicit init so the injected `model` doesn't perturb the synthesized memberwise initializer (which would otherwise pull the environment objects into the required parameters).
    init(model: NavigatorModel, activeEditorURL: Binding<URL?>, onRequestOpen: @escaping (URL) -> Void) {
        _model = ObservedObject(wrappedValue: model)
        _activeEditorURL = activeEditorURL
        self.onRequestOpen = onRequestOpen
    }

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
        // Keep the tracking status in sync with the project, the active mode, and tree reloads.
        .onChange(of: store.currentProject?.url) { _ in refreshTracking() }
        .onAppear { refreshTracking() }
        // Re-run the active mode's status when the mode switches, and on every tree reload (which also fires when an external tool rewrites `.git/index`).
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
                            trackingMode: store.trackingMode,
                            activeEditorURL: activeEditorURL,
                            renamingURL: renamingURL,
                            renameDraft: $renameDraft,
                            glowingFolder: glowingFolder,
                            dropTargetFolder: dropTargetFolder,
                            draggedURL: draggedURL,
                            onOpen: openFile,
                            onToggle: toggleFolder,
                            onStartRename: startRename,
                            onCommitRename: commitRename,
                            onCancelRename: cancelRename,
                            onDelete: requestDelete,
                            onDragChanged: dragChanged,
                            onDragEnded: dragEnded
                        )
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.top, 4)
                .contentShape(Rectangle())
            }
            // Track row frames and host the drag overlay in one shared coordinate space, so the cursor location, the tracked rects, and the floating preview all agree.
            .coordinateSpace(name: navCoordinateSpace)
            .onPreferenceChange(RowFrameKey.self) { itemFrames = $0 }
            .overlay(dragOverlay)

            if store.trackingMode == .git && !git.isRepository {
                trackingNotice("Git has not been initialized.")
            }

            modeToggle
        }
        .padding(.vertical, verticalMargin)
        .padding(.horizontal, horizontalMargin)
    }

    private func refreshTracking() {
        switch store.trackingMode {
        case .regular:
            break
        case .git:
            git.refresh(projectURL: store.currentProject?.url)
        }
    }

    private func trackingNotice(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundColor(appColors.uiTextMuted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 6)
    }

    // MARK: - Row actions

    // Opening a file or toggling a folder counts as "doing something else", so it cancels any in-progress rename rather than leaving a stray text field behind.
    // Blobs and images open in the content region; any other file type is handed to the OS.
    private func openFile(_ url: URL) {
        cancelRename()
        if url.isBlobFile || url.isImageFile {
            onRequestOpen(url)
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    private func toggleFolder(_ node: FileNode) {
        cancelRename()
        model.toggle(node)
    }

    // MARK: - Drag and drop

    // Called continuously while a blob row is dragged.
    // The first call latches the dragged blob (its row stays in place but is rendered invisibly — see `FileRowView`/`isDragged` — so the gesture's owning view is never destroyed mid-drag). Each call moves the floating overlay to the cursor and resolves which folder the cursor is hovering, via the tracked row frames.
    private func dragChanged(_ node: FileNode, _ location: CGPoint) {
        if draggedURL == nil {
            draggedURL = node.url
            draggedName = node.name
            draggedIsDirectory = node.isDirectory
        }
        guard sameFile(draggedURL, node.url) else { return }
        dragLocation = location

        // The row under the cursor (its frame is collapsed to zero while dragged, so the dragged item never matches itself). No row → empty space → project root.
        let hitURL = itemFrames.first(where: { $0.value.contains(location) })?.key
        let candidate = hitURL
            .flatMap { model.node(matching: $0) }
            .map { model.dropDestination(for: $0) } ?? nil

        // A folder cannot be dropped into itself or any descendant.
        // The dragged folder's own row is collapsed and so never hit-tests, but its still-rendered children can, so guard explicitly.
        // When invalid we clear the highlight and flag the drop, rather than letting `candidate` fall through to a root move.
        if node.isDirectory, let candidate = candidate,
           sameFile(candidate, node.url) || isWithin(candidate, folder: node.url) {
            dropInvalid = true
            dropTargetFolder = nil
        } else {
            dropInvalid = false
            dropTargetFolder = candidate
        }
    }

    // Called when the drag is released.
    // Clears the drag overlay first (so nothing lingers), then performs the move into the resolved folder (nil = project root).
    // The model move no-ops when the item already lives in that folder, and a folder move into itself/a descendant was already rejected as `dropInvalid` during the drag.
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

        // Keep the open editor pointed at the right file, and broadcast the move so each mini-view window can follow its own blob.
        let move = BlobMoveInfo(old: dragged, new: newURL, isDirectory: node.isDirectory)
        if let active = activeEditorURL, let repointed = repointedURL(active, forMove: move) {
            activeEditorURL = repointed
        }
        NotificationCenter.default.post(name: .blobMoved, object: move)

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
                    .foregroundColor(appColors.uiTextHeading)
                Text(draggedName)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .foregroundColor(appColors.uiTextHeading)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(appColors.uiSunken)
            .cornerRadius(5)
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(appColors.uiBorder, lineWidth: 1))
            .frame(width: 160, alignment: .leading)
            .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
            .position(dragLocation)
            .allowsHitTesting(false)
        }
    }

    // Briefly flashes the confirmation glow on a folder that just received a dropped blob.
    // The glow start is deferred one runloop tick so it lands after the move's `reload()` has re-sorted the rows. Otherwise the glow attaches to the destination at its pre-move slot and then slides with the row to its new position. The wait is imperceptible.
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
        renameDraft = url.lastPathComponent
        renamingURL = url
    }

    private func cancelRename() {
        renamingURL = nil
    }

    // Commits the new file name. No-ops on an empty or unchanged name. Repoints the open editor and broadcasts the move so each mini-view window follows its own blob (renaming a folder rebases blobs inside it).
    private func commitRename(_ node: FileNode) {
        defer { renamingURL = nil }
        let trimmed = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != node.name else { return }
        let newURL = model.rename(node, to: trimmed, using: store)
        guard let newURL = newURL else { return }
        let move = BlobMoveInfo(old: node.url, new: newURL, isDirectory: node.isDirectory)
        if let active = activeEditorURL, let repointed = repointedURL(active, forMove: move) {
            activeEditorURL = repointed
        }
        NotificationCenter.default.post(name: .blobMoved, object: move)
    }

    private func requestDelete(_ node: FileNode) {
        pendingDelete = node
    }

    // Performs the confirmed delete. Clears the open editor if it held the deleted item, and broadcasts the deletion so any mini-view window on it closes (see MiniView).
    private func performDelete(_ node: FileNode) {
        if let active = activeEditorURL, isAffected(active, byDeletionOf: node.url) {
            activeEditorURL = nil
        }
        NotificationCenter.default.post(name: .blobDeleted, object: node.url)
        model.delete(node, using: store)
    }

    // MARK: - Header

    private func headerRow(project: Project) -> some View {
        HStack(spacing: 8) {
            Text(project.name.uppercased())
                .font(.system(size: 12, weight: .semibold))
                .tracking(0.5)
                .foregroundColor(appColors.uiTextHeading)
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
            .foregroundColor(appColors.uiTextMuted)
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
                    .fill(appColors.uiSunken)

                RoundedRectangle(cornerRadius: r)
                    .fill(appColors.uiTextHeading.opacity(0.9))
                    .frame(width: slotW - 6, height: h - 6)
                    .offset(x: selectedIdx * slotW + 3)
                    .animation(.spring(response: 0.2, dampingFraction: 0.92), value: store.trackingMode)

                HStack(spacing: 0) {
                    ForEach(modes, id: \.self) { mode in
                        Button { store.setTrackingMode(mode) } label: {
                            Text(mode.label)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(
                                    store.trackingMode == mode ? appColors.uiSurface
                                    : appColors.uiTextResting
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

// Compares two file URLs by their resolved filesystem path.
// Needed because `contentsOfDirectory` returns directory URLs with a trailing slash and with symlinks resolved (e.g. /var → /private/var), so a freshly created item's URL won't be `==` to its tree representation even when they point at the same file.
func sameFile(_ a: URL?, _ b: URL) -> Bool {
    guard let a = a else { return false }
    return a.resolvingSymlinksInPath().path == b.resolvingSymlinksInPath().path
}

// True if `url` lives anywhere inside `folder`. Resolves symlinks so the comparison survives the trailing-slash / `/var`→`/private/var` differences that `contentsOfDirectory` URLs carry.
func isWithin(_ url: URL, folder: URL) -> Bool {
    let f = folder.resolvingSymlinksInPath().path
    let u = url.resolvingSymlinksInPath().path
    return u.hasPrefix(f + "/")
}

// MARK: - Row indicators

// The trailing status mark on a row, resolved to concrete colors so FileRowView only has to draw it. `.badges` is a file's letter badges (up to two for git); `.dot` is a folder's aggregate.
enum RowIndicator: Equatable {
    case none
    case badges([RowBadge])
    case dot(Color)
}

struct RowBadge: Hashable {
    let letter: String
    let color: Color
}

#Preview {
    FileNavigatorView(model: NavigatorModel(), activeEditorURL: .constant(nil), onRequestOpen: { _ in })
        .environmentObject(ProjectStore())
        .environmentObject(AppColors.shared)
        .frame(width: 254)
}
