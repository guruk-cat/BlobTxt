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

    // Mode selector state. Binary selector (Git vs Blaze); behavior is a future feature.
    @State private var blazeMode: Bool = false

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
    // blob is drawn by us as a plain SwiftUI overlay (`dragOverlay`). Clearing `draggedURL` erases
    // that overlay instantly on drop, so there is no OS image to linger.
    //
    // `draggedURL`/`draggedName` identify the blob currently being dragged (nil = no drag).
    // `dragLocation` is the cursor position (in `navCoordinateSpace`) where the overlay is drawn.
    // `itemFrames` are the tracked row rects used to hit-test which folder the cursor is over.
    // `dropTargetFolder` is that resolved folder (nil = project root); it drives the folder-scoped
    // highlight box. `glowingFolder` is the folder flashing the post-drop confirmation glow.
    @State private var draggedURL: URL? = nil
    @State private var draggedName: String = ""
    @State private var dragLocation: CGPoint = .zero
    @State private var itemFrames: [URL: CGRect] = [:]
    @State private var dropTargetFolder: URL? = nil
    @State private var glowingFolder: URL? = nil

    // Outer panel margins. Vertical is intentionally thicker than horizontal (see plan §2.4).
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
        }
        .onAppear {
            if let url = store.currentProject?.url { model.activate(projectURL: url) }
        }
        .onDisappear { model.deactivate() }
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

    // Top-level layout: a fixed header and mode toggle bracket a scrollable tree.
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

            modeToggle
        }
        .padding(.vertical, verticalMargin)
        .padding(.horizontal, horizontalMargin)
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
        }
        guard sameFile(draggedURL, node.url) else { return }
        dragLocation = location

        // The row under the cursor (its frame is collapsed to zero while dragged, so the dragged
        // blob never matches itself). No row → empty space → project root.
        let hitURL = itemFrames.first(where: { $0.value.contains(location) })?.key
        if let hitURL = hitURL, let hitNode = model.node(matching: hitURL) {
            dropTargetFolder = model.dropDestination(for: hitNode)
        } else {
            dropTargetFolder = nil
        }
    }

    // Called when the drag is released. Clears the drag overlay first (so nothing lingers), then
    // performs the move into the resolved folder (nil = project root). `moveBlob` no-ops when the
    // blob is already in that folder.
    private func dragEnded(_ node: FileNode) {
        guard sameFile(draggedURL, node.url) else { clearDrag(); return }
        let target = dropTargetFolder
        let dragged = node.url
        clearDrag()

        guard let newURL = model.moveBlob(dragged, into: target, using: store) else { return }
        if sameFile(activeEditorURL, dragged) { activeEditorURL = newURL }
        if let target = target { triggerGlow(target) }
    }

    private func clearDrag() {
        draggedURL = nil
        draggedName = ""
        dragLocation = .zero
        dropTargetFolder = nil
    }

    // The floating drag preview: a plain SwiftUI view following the cursor. Because it is ours (not
    // an OS drag image), clearing `draggedURL` removes it immediately, with no ghosting.
    @ViewBuilder
    private var dragOverlay: some View {
        if draggedURL != nil {
            HStack(spacing: 5) {
                Image(systemName: "doc.text")
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
    //
    // The fade is driven by a view-local `.animation(value:)` on the glow overlay rather than a
    // global `withAnimation`, so it stays scoped to that one rectangle.
    //
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
    // The display name is the filename without the `.md` extension (folders have none).
    private func beginRename(url: URL) {
        renameDraft = url.pathExtension == "md"
            ? url.deletingPathExtension().lastPathComponent
            : url.lastPathComponent
        renamingURL = url
    }

    private func cancelRename() {
        renamingURL = nil
    }

    // Commits the draft name. No-ops on an empty or unchanged name. If the renamed blob is
    // the one open in the editor, the active URL is repointed so the editor stays in sync.
    private func commitRename(_ node: FileNode) {
        defer { renamingURL = nil }
        let trimmed = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != node.name else { return }
        let newURL = model.rename(node, to: trimmed, using: store)
        if let newURL = newURL, activeEditorURL == node.url {
            activeEditorURL = newURL
        }
    }

    private func requestDelete(_ node: FileNode) {
        pendingDelete = node
    }

    // Performs the confirmed delete. Clears the editor if the open blob was deleted or lived
    // inside a deleted folder.
    private func performDelete(_ node: FileNode) {
        if let active = activeEditorURL,
           active == node.url || active.path.hasPrefix(node.url.path + "/") {
            activeEditorURL = nil
        }
        model.delete(node, using: store)
    }

    // MARK: - Header

    // Project name on the left; new-folder and new-blob action buttons on the right.
    private func headerRow(project: Project) -> some View {
        HStack(spacing: 8) {
            Text(project.name.uppercased())
                .font(.system(size: 11, weight: .semibold))
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

    // "MODE:" header above a Git ⟷ Blaze selector. Git is right-aligned and Blaze left-aligned
    // so both labels hug the centered switch. No tint distinction since this is a binary selector,
    // not an on/off control.
    private var modeToggle: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("MODE:")
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.5)
                .foregroundColor(appColors.textHeading)

            HStack(spacing: 8) {
                Text("Git")
                    .frame(maxWidth: .infinity, alignment: .trailing)
                Toggle("", isOn: $blazeMode)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .tint(appColors.textMuted)
                Text("Blaze")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.system(size: 12))
            .foregroundColor(appColors.textResting)
        }
        .padding(.horizontal, 6)
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

// MARK: - Recursive tree rows

// Renders a list of sibling nodes at a given depth, recursing into expanded folders.
private struct NodeRowsView: View {
    let nodes: [FileNode]
    let depth: Int
    @ObservedObject var model: NavigatorModel
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
            // The row highlights when it lies inside the currently targeted folder, so an entire
            // folder's contents glow as one box.
            FileRowView(
                node: node,
                depth: depth,
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
    }

    // True when `url` is the currently targeted folder or lives anywhere inside it. A nil target
    // (project root or no drag) highlights nothing, so dropping to root stays unhighlighted.
    private func isInTargetedFolder(_ url: URL) -> Bool {
        guard let target = dropTargetFolder else { return false }
        return sameFile(target, url) || isWithin(url, folder: target)
    }
}

// A single navigator row. Folders lead with a chevron, blobs with a file icon.
// The whole row is the tap target. The trailing Spacer reserves room for a future
// right-end indicator.
//
// Background indication is a single priority chain (see `rowBackground`): the drag drop-highlight
// (this row is inside the folder a drag is hovering into) wins, then the open blob's selection tint,
// then a folder being the context directory, then plain hover. The open-blob tint and hover are
// therefore mutually exclusive. Folders also flash a confirmation glow overlay when a blob is
// dropped into them.
private struct FileRowView: View {
    @EnvironmentObject var appColors: AppColors

    let node: FileNode
    let depth: Int
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
    // Manual drag gesture callbacks. `changed` reports the cursor location in `navCoordinateSpace`.
    let onDragChanged: (CGPoint) -> Void
    let onDragEnded: () -> Void

    @FocusState private var fieldFocused: Bool
    @State private var hovering = false

    private let indentStep: CGFloat = 12

    var body: some View {
        // Only blobs are draggable. The gesture coexists with tap/contextMenu via `simultaneousGesture`
        // and a minimum distance so a click still registers as a tap. It is omitted while renaming so
        // the text field keeps normal mouse behavior.
        if !node.isDirectory && !isRenaming {
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
            Spacer(minLength: 0)
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
        }
    }

    // Single source of truth for the row's background tint. Order encodes priority.
    private var rowBackground: Color {
        if isDropHighlighted {
            return appColors.metaIndication.opacity(0.12)
        } else if isSelected {
            return appColors.metaIndication.opacity(0.08)
        } else if isContext {
            return appColors.surfaceRaised.opacity(0.5)
        } else if hovering {
            return appColors.surfaceRaised.opacity(0.25)
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

// Header action button: textBody at rest, metaIndication on hover, and a brief
// metaConfirmation glow when clicked.
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
                    : appColors.textBody
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
