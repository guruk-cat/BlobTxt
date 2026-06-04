import SwiftUI

// MARK: - Item frame tracking
struct ItemFrameKey: PreferenceKey {
    typealias Value = [UUID: CGRect]
    static var defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

struct FileNavigatorView: View {

    @EnvironmentObject var store: ProjectStore
    @EnvironmentObject var appColors: AppColors
    @StateObject private var crossPanelDrag = CrossPanelDrag()
    @Binding var selectedProjectID: UUID?
    @Binding var activeBlobID: UUID?
    // Hoisted to SidebarView so state persists when the navigator panel is closed and re-opened.
    @Binding var expandedFolderIDs: Set<UUID>
    @Binding var selectedFolderID: UUID?

    @State private var isRenamingFolder = false
    @State private var renameFolderID: UUID?
    @State private var renameFolderProjectID: UUID?
    @State private var renameFolderText = ""

    @State private var hoverNewFolder: Bool = false
    @State private var hoverNewBlob: Bool = false

    // MARK: - Drag state
    //
    // Key invariant: the dragged item is NEVER removed from its source display list while
    // a drag is active. Removing it destroys the view that owns the DragGesture, preventing
    // .onEnded from firing and leaving clearDragState() uncalled. Keep it at height 0 / opacity 0.
    @State private var draggedItemID: UUID? = nil
    @State private var draggedProjectID: UUID? = nil
    // nil → dragging a folder or root-level blob
    // UUID → dragging a blob that lives inside that folder
    @State private var dragSourceFolderID: UUID? = nil
    @State private var dragLocation: CGPoint = .zero
    @State private var itemFrames: [UUID: CGRect] = [:]
    @State private var ghostFolderIndex: Int? = nil
    @State private var ghostRootBlobIndex: Int? = nil
    @State private var ghostFolderBlobIndex: Int? = nil
    @State private var hoveredFolderID: UUID? = nil
    @State private var confirmGlowItemID: UUID? = nil
    @State private var confirmGlowOpacity: Double = 0.0

    @State private var hoveredRowID: UUID? = nil

    static let rowHeight: CGFloat = 26

    // MARK: - Body

    var body: some View {
        if let id = selectedProjectID,
           let project = store.projects.first(where: { $0.id == id }) {
            level2ProjectView(project)
                .onChange(of: selectedProjectID) { _ in
                    expandedFolderIDs = []
                    selectedFolderID = nil
                }
        } else {
            noProjectView
        }
    }

    // MARK: - No-project empty state

    private var noProjectView: some View {
        Color.clear
    }

    // MARK: - Project contents

    @ViewBuilder
    private func level2ProjectView(_ project: Project) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // Header: project name + new folder/blob buttons
                HStack(spacing: 6) {
                    Text(project.name.uppercased())
                        .font(.system(size: 11, weight: .semibold))
                        .tracking(0.5)
                        .foregroundColor(AppColors.shared.textHeading)
                    Spacer()
                    Button {
                        let folder = store.createFolder(in: project.id, name: "Untitled Folder")
                        expandedFolderIDs.insert(folder.id)
                        selectedFolderID = folder.id
                    } label: {
                        Image(systemName: "folder.badge.plus")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(hoverNewFolder ? AppColors.shared.textBody : AppColors.shared.textMuted)
                    }
                    .buttonStyle(.plain)
                    .onHover { hoverNewFolder = $0 }
                    .padding(.trailing, 4)

                    Button {
                        _ = store.createBlob(in: project.id, folderID: selectedFolderID)
                    } label: {
                        Image(systemName: "doc.badge.plus")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(hoverNewBlob ? AppColors.shared.textBody : AppColors.shared.textMuted)
                    }
                    .buttonStyle(.plain)
                    .onHover { hoverNewBlob = $0 }
                }
                .padding(.leading, 12)
                .padding(.trailing, 8)
                .padding(.top, 12)
                .padding(.bottom, 4)

                // Folders and root blobs
                let folders = displayFolders(for: project)
                let rootBlobs = displayRootBlobs(for: project)

                VStack(alignment: .leading, spacing: 0) {
                    // Folders
                    ForEach(folders) { item in
                        if case .ghost = item {
                            treeGhost()
                                .padding(.leading, 26)
                                .padding(.vertical, 1)
                        } else if case .folder(let folder) = item {
                            let isDragged = draggedItemID == folder.id
                            detailedFolderRow(folder, in: project)
                                .frame(height: isDragged ? 0 : nil)
                                .clipped()
                                .opacity(isDragged ? 0 : 1)
                        }
                    }
                    .animation(.spring(response: 0.25, dampingFraction: 0.82),
                               value: folders.map(\.id))

                    // Root blobs
                    ForEach(rootBlobs) { item in
                        if case .ghost = item {
                            treeGhost()
                                .padding(.leading, 26)
                                .padding(.vertical, 1)
                        } else if case .blob(let blob) = item {
                            let isDragged = draggedItemID == blob.id
                            let isInvisible = isDragged
                            BlobTreeRow(
                                blob: blob, projectID: project.id,
                                isActive: activeBlobID == blob.id,
                                isGlowing: confirmGlowItemID == blob.id,
                                glowOpacity: confirmGlowItemID == blob.id ? confirmGlowOpacity : 0,
                                indent: 26
                            )
                            .frame(height: Self.rowHeight)
                            .frame(height: isInvisible ? 0 : nil)
                            .clipped()
                            .opacity(isInvisible ? 0 : 1)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                selectedProjectID = project.id
                                selectedFolderID = nil
                                activeBlobID = blob.id
                            }
                            .background(frameTracker(.blob(blob)))
                            .simultaneousGesture(
                                rootBlobDrag(blob: blob, project: project),
                                including: .all
                            )
                            .contextMenu { blobContextMenu(blob, project: project, isInFolder: false) }
                        }
                    }
                    .animation(.spring(response: 0.25, dampingFraction: 0.82),
                               value: rootBlobs.map(\.id))
                }
                .padding(.bottom, 60)
            }
        }
        .coordinateSpace(name: "sidebarNav")
        .onPreferenceChange(ItemFrameKey.self) { itemFrames = $0 }
        .overlay(dragOverlay)
        .environmentObject(crossPanelDrag)
        .alert("Rename Folder", isPresented: $isRenamingFolder) {
            TextField("Folder name", text: $renameFolderText)
            Button("Cancel", role: .cancel) {}
            Button("Rename") {
                if let fid = renameFolderID, let pid = renameFolderProjectID {
                    store.renameFolder(fid, in: pid, to: renameFolderText)
                }
            }
        }
    }

    // MARK: - Folder expansion helpers

    private func isFolderExpanded(_ folder: BlobFolder) -> Bool {
        expandedFolderIDs.contains(folder.id)
    }

    // MARK: - Detailed folder row

    @ViewBuilder
    private func detailedFolderRow(_ folder: BlobFolder, in project: Project) -> some View {
        let folderExpanded = isFolderExpanded(folder)
        let hasBlobs = project.blobs.contains { $0.folderID == folder.id }
        let isDragHovered = hoveredFolderID == folder.id
            || (crossPanelDrag.activeProjectID == project.id && crossPanelDrag.targetFolderID == folder.id)
        let isGlowing = confirmGlowItemID == folder.id
        let blobs = displayFolderBlobs(folder: folder, project: project)

        let isFolderSelected = selectedFolderID == folder.id && activeBlobID == nil
        let isRowHovered = hoveredRowID == folder.id

        VStack(alignment: .leading, spacing: 0) {
            // Folder header row
            HStack(spacing: 4) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 11))
                    .foregroundColor(
                        isDragHovered ? AppColors.shared.metaIndication : AppColors.shared.textResting)
                Text(folder.name)
                    .font(.system(size: 12))
                    .foregroundColor(
                        isDragHovered ? AppColors.shared.metaIndication : AppColors.shared.textResting)
                    .lineLimit(1)
                Spacer()
            }
            .padding(.leading, 26).padding(.trailing, 8).padding(.vertical, 4)
            .overlay(alignment: .leading) {
                Image(systemName: folderExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(hasBlobs ? AppColors.shared.textResting : Color.clear)
                    .frame(width: 14)
                    .padding(.leading, 8)
            }
            .frame(height: Self.rowHeight)
            .background(
                isDragHovered
                    ? AppColors.shared.metaIndication.opacity(0.12)
                    : isFolderSelected
                        ? AppColors.shared.surfaceRaised.opacity(0.5)
                        : isRowHovered
                            ? AppColors.shared.surfaceRaised.opacity(0.25)
                            : Color.clear
            )
            .overlay(
                isGlowing
                    ? RoundedRectangle(cornerRadius: 4)
                        .fill(AppColors.shared.metaConfirmation.opacity(confirmGlowOpacity * 0.3))
                    : nil
            )
            .contentShape(Rectangle())
            .onHover { h in
                hoveredRowID = h ? folder.id : (hoveredRowID == folder.id ? nil : hoveredRowID)
                if crossPanelDrag.activeBlobID != nil && crossPanelDrag.activeProjectID == project.id {
                    crossPanelDrag.targetFolderID = h ? folder.id : (crossPanelDrag.targetFolderID == folder.id ? nil : crossPanelDrag.targetFolderID)
                }
            }
            .onTapGesture {
                if folderExpanded {
                    expandedFolderIDs.remove(folder.id)
                    selectedFolderID = nil
                } else {
                    expandedFolderIDs.insert(folder.id)
                    selectedFolderID = folder.id
                }
            }
            .background(frameTracker(.folder(folder)))
            .simultaneousGesture(folderDrag(folder: folder, project: project))
            .contextMenu {
                Button {
                    renameFolderID = folder.id; renameFolderProjectID = project.id
                    renameFolderText = folder.name; isRenamingFolder = true
                } label: { Label("Rename Folder", systemImage: "pencil") }
                Divider()
                Button(role: .destructive) {
                    store.deleteFolder(folder.id, in: project.id)
                } label: { Label("Delete Folder", systemImage: "trash") }
            }

            // Blobs inside folder (when expanded)
            if folderExpanded {
                ForEach(blobs) { item in
                    if case .ghost = item {
                        treeGhost()
                            .padding(.leading, 42)
                            .padding(.vertical, 1)
                    } else if case .blob(let blob) = item {
                        let isDragged = draggedItemID == blob.id
                        let isLeaving = isDragged
                        BlobTreeRow(
                            blob: blob, projectID: project.id,
                            isActive: activeBlobID == blob.id,
                            isGlowing: confirmGlowItemID == blob.id,
                            glowOpacity: confirmGlowItemID == blob.id ? confirmGlowOpacity : 0,
                            indent: 42
                        )
                        .frame(height: Self.rowHeight)
                        .frame(height: isLeaving ? 0 : nil)
                        .clipped()
                        .opacity(isLeaving ? 0 : 1)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            selectedProjectID = project.id
                            selectedFolderID = folder.id
                            activeBlobID = blob.id
                        }
                        .background(frameTracker(.blob(blob)))
                        .simultaneousGesture(
                            folderBlobDrag(blob: blob, project: project, sourceFolderID: folder.id),
                            including: .all
                        )
                        .contextMenu { blobContextMenu(blob, project: project, isInFolder: true) }
                    }
                }
                .animation(.spring(response: 0.25, dampingFraction: 0.82),
                           value: blobs.map(\.id))
            }
        }
    }

    // MARK: - Ghost row

    private func treeGhost() -> some View {
        RoundedRectangle(cornerRadius: 4)
            .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [4, 4]))
            .foregroundColor(AppColors.shared.textMuted.opacity(0.4))
            .frame(height: Self.rowHeight - 4)
    }

    // MARK: - Frame tracker

    private func frameTracker(_ item: NavigatorItem) -> some View {
        GeometryReader { geo in
            Color.clear.preference(
                key: ItemFrameKey.self,
                value: [item.id: geo.frame(in: .named("sidebarNav"))]
            )
        }
    }

    // MARK: - Drag overlay

    @ViewBuilder
    private var dragOverlay: some View {
        if let id = draggedItemID, let pid = draggedProjectID,
           let project = store.projects.first(where: { $0.id == pid }) {
            Group {
                if let folder = project.folders.first(where: { $0.id == id }) {
                    dragPreview(icon: "folder.fill", text: folder.name)
                } else if let blob = project.blobs.first(where: { $0.id == id }) {
                    BlobDragPreview(blob: blob, projectID: pid)
                        .environmentObject(store)
                }
            }
            .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
            .position(x: dragLocation.x, y: dragLocation.y)
            .allowsHitTesting(false)
        }
    }

    private func dragPreview(icon: String, text: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 11))
                .foregroundColor(AppColors.shared.textHeading)
            Text(text).font(.system(size: 12)).lineLimit(1)
                .foregroundColor(AppColors.shared.textHeading)
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(AppColors.shared.surface)
        .cornerRadius(5)
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(AppColors.shared.borderCard, lineWidth: 1))
        .frame(width: 160, alignment: .leading)
    }

    // MARK: - Display lists

    private func displayFolders(for project: Project) -> [NavigatorItem] {
        var all = project.folders.sorted { $0.sortOrder < $1.sortOrder }.map(NavigatorItem.folder)
        guard let id = draggedItemID,
              draggedProjectID == project.id,
              dragSourceFolderID == nil,
              let dragPos = all.firstIndex(where: { $0.id == id }),
              let ghostIdx = ghostFolderIndex else { return all }
        let insertAt = min(max(ghostIdx <= dragPos ? ghostIdx : ghostIdx + 1, 0), all.count)
        all.insert(.ghost, at: insertAt)
        return all
    }

    private func displayRootBlobs(for project: Project) -> [NavigatorItem] {
        var all = project.blobs
            .filter { $0.folderID == nil }
            .sorted { $0.sortOrder < $1.sortOrder }
            .map(NavigatorItem.blob)
        guard let id = draggedItemID, draggedProjectID == project.id else { return all }

        if dragSourceFolderID == nil, let dragPos = all.firstIndex(where: { $0.id == id }) {
            guard hoveredFolderID == nil, let ghostIdx = ghostRootBlobIndex else { return all }
            let insertAt = min(max(ghostIdx <= dragPos ? ghostIdx : ghostIdx + 1, 0), all.count)
            all.insert(.ghost, at: insertAt)
        } else if dragSourceFolderID != nil {
            if let ghostIdx = ghostRootBlobIndex {
                all.insert(.ghost, at: max(0, min(ghostIdx, all.count)))
            }
        }
        return all
    }

    private func displayFolderBlobs(folder: BlobFolder, project: Project) -> [NavigatorItem] {
        var all = project.blobs
            .filter { $0.folderID == folder.id }
            .sorted { $0.sortOrder < $1.sortOrder }
            .map(NavigatorItem.blob)
        guard let id = draggedItemID,
              draggedProjectID == project.id,
              dragSourceFolderID == folder.id,
              let dragPos = all.firstIndex(where: { $0.id == id }) else { return all }

        if hoveredFolderID != nil || ghostRootBlobIndex != nil { return all }

        guard let ghostIdx = ghostFolderBlobIndex else { return all }
        let insertAt = min(max(ghostIdx <= dragPos ? ghostIdx : ghostIdx + 1, 0), all.count)
        all.insert(.ghost, at: insertAt)
        return all
    }

    // MARK: - Ghost index helper
    private func ghostIndex(cursor: CGPoint, among items: [NavigatorItem]) -> Int {
        let framed: [(Int, CGRect)] = items.enumerated().compactMap { i, item in
            guard let f = itemFrames[item.id] else { return nil }
            return (i, f)
        }.sorted { $0.1.minY < $1.1.minY }
        guard !framed.isEmpty else { return 0 }
        for (i, frame) in framed {
            if cursor.y < frame.midY { return i }
        }
        return framed.count
    }

    // MARK: - Drag gestures

    private func folderDrag(folder: BlobFolder, project: Project) -> some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .named("sidebarNav"))
            .onChanged { v in
                if draggedItemID == nil {
                    draggedItemID = folder.id
                    draggedProjectID = project.id
                    dragSourceFolderID = nil
                }
                guard draggedItemID == folder.id else { return }
                dragLocation = v.location
                let others = project.folders.sorted { $0.sortOrder < $1.sortOrder }
                    .filter { $0.id != folder.id }.map(NavigatorItem.folder)
                ghostFolderIndex = ghostIndex(cursor: v.location, among: others)
                ghostRootBlobIndex = nil; ghostFolderBlobIndex = nil; hoveredFolderID = nil
            }
            .onEnded { _ in
                guard draggedItemID == folder.id else { return }
                defer { clearDragState() }
                guard let ghostIdx = ghostFolderIndex else { return }
                let current = store.projects.first { $0.id == project.id } ?? project
                let sorted = current.folders.sorted { $0.sortOrder < $1.sortOrder }
                guard let from = sorted.firstIndex(where: { $0.id == folder.id }) else { return }
                let to = min(max(ghostIdx, 0), sorted.count - 1)
                guard to != from else { return }
                store.moveItem(in: project.id, fromIndex: from, toIndex: to, context: nil)
                triggerGlow(for: folder.id)
            }
    }

    private func rootBlobDrag(blob: Blob, project: Project) -> some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .named("sidebarNav"))
            .onChanged { v in
                if draggedItemID == nil {
                    draggedItemID = blob.id
                    draggedProjectID = project.id
                    dragSourceFolderID = nil
                }
                guard draggedItemID == blob.id else { return }
                dragLocation = v.location
                ghostFolderBlobIndex = nil
                let current = store.projects.first { $0.id == project.id } ?? project
                for f in current.folders {
                    if let frame = itemFrames[f.id], frame.contains(v.location) {
                        hoveredFolderID = f.id; ghostRootBlobIndex = nil; return
                    }
                }
                hoveredFolderID = nil
                let others = current.blobs.filter { $0.folderID == nil && $0.id != blob.id }
                    .sorted { $0.sortOrder < $1.sortOrder }.map(NavigatorItem.blob)
                ghostRootBlobIndex = ghostIndex(cursor: v.location, among: others)
            }
            .onEnded { _ in
                guard draggedItemID == blob.id else { return }
                defer { clearDragState() }
                let current = store.projects.first { $0.id == project.id } ?? project
                if let target = hoveredFolderID {
                    store.moveBlobToFolder(blob.id, to: target, in: project.id)
                    triggerGlow(for: target); return
                }
                guard let ghostIdx = ghostRootBlobIndex else { return }
                let rootBlobs = current.blobs.filter { $0.folderID == nil }
                    .sorted { $0.sortOrder < $1.sortOrder }
                guard let from = rootBlobs.firstIndex(where: { $0.id == blob.id }) else { return }
                let to = min(max(ghostIdx, 0), rootBlobs.count - 1)
                guard to != from else { return }
                store.moveItem(in: project.id, fromIndex: current.folders.count + from,
                               toIndex: current.folders.count + to, context: nil)
                triggerGlow(for: blob.id)
            }
    }

    private func folderBlobDrag(blob: Blob, project: Project, sourceFolderID: UUID) -> some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .named("sidebarNav"))
            .onChanged { v in
                if draggedItemID == nil {
                    draggedItemID = blob.id
                    draggedProjectID = project.id
                    dragSourceFolderID = sourceFolderID
                }
                guard draggedItemID == blob.id else { return }
                dragLocation = v.location
                let current = store.projects.first { $0.id == project.id } ?? project
                for f in current.folders where f.id != sourceFolderID {
                    if let frame = itemFrames[f.id], frame.contains(v.location) {
                        hoveredFolderID = f.id
                        ghostFolderBlobIndex = nil; ghostRootBlobIndex = nil; return
                    }
                }
                hoveredFolderID = nil
                let rootBlobItems = current.blobs.filter { $0.folderID == nil }
                    .sorted { $0.sortOrder < $1.sortOrder }.map(NavigatorItem.blob)
                let folderBlobItems = current.blobs.filter { $0.folderID == sourceFolderID }
                    .sorted { $0.sortOrder < $1.sortOrder }.map(NavigatorItem.blob)
                let folderMaxY = folderBlobItems.compactMap { itemFrames[$0.id]?.maxY }.max() ?? 0
                let isOverRoot = rootBlobItems.contains {
                    itemFrames[$0.id].map { $0.insetBy(dx: 0, dy: -6).contains(v.location) } ?? false
                }
                let isBelowFolder = v.location.y > folderMaxY + 6

                if isOverRoot || isBelowFolder {
                    let others = rootBlobItems.filter { $0.id != blob.id }
                    ghostRootBlobIndex = ghostIndex(cursor: v.location, among: others)
                    ghostFolderBlobIndex = nil
                } else {
                    let others = folderBlobItems.filter { $0.id != blob.id }
                    ghostFolderBlobIndex = ghostIndex(cursor: v.location, among: others)
                    ghostRootBlobIndex = nil
                }
            }
            .onEnded { _ in
                guard draggedItemID == blob.id else { return }
                defer { clearDragState() }
                let current = store.projects.first { $0.id == project.id } ?? project
                if let target = hoveredFolderID {
                    store.moveBlobToFolder(blob.id, to: target, in: project.id)
                    triggerGlow(for: target); return
                }
                if let ghostIdx = ghostRootBlobIndex {
                    store.moveBlobToRoot(blob.id, in: project.id)
                    let updated = store.projects.first { $0.id == project.id } ?? current
                    let rootBlobs = updated.blobs.filter { $0.folderID == nil }
                        .sorted { $0.sortOrder < $1.sortOrder }
                    if let from = rootBlobs.firstIndex(where: { $0.id == blob.id }) {
                        let to = min(max(ghostIdx, 0), rootBlobs.count - 1)
                        if to != from {
                            store.moveItem(in: project.id,
                                           fromIndex: updated.folders.count + from,
                                           toIndex:   updated.folders.count + to,
                                           context: nil)
                        }
                    }
                    triggerGlow(for: blob.id); return
                }
                if let ghostIdx = ghostFolderBlobIndex {
                    let folderBlobs = current.blobs.filter { $0.folderID == sourceFolderID }
                        .sorted { $0.sortOrder < $1.sortOrder }
                    guard let from = folderBlobs.firstIndex(where: { $0.id == blob.id }) else { return }
                    let to = min(max(ghostIdx, 0), folderBlobs.count - 1)
                    guard to != from else { return }
                    store.moveItem(in: project.id, fromIndex: from, toIndex: to, context: sourceFolderID)
                    triggerGlow(for: blob.id)
                }
            }
    }

    // MARK: - Helpers

    private func clearDragState() {
        draggedItemID = nil; draggedProjectID = nil; dragSourceFolderID = nil
        dragLocation = .zero; ghostFolderIndex = nil; ghostRootBlobIndex = nil
        ghostFolderBlobIndex = nil; hoveredFolderID = nil
    }

    private func triggerGlow(for id: UUID) {
        confirmGlowItemID = id; confirmGlowOpacity = 1.0
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            withAnimation(.easeOut(duration: 0.4)) { confirmGlowOpacity = 0.0 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { confirmGlowItemID = nil }
        }
    }

    @ViewBuilder
    private func blobContextMenu(_ blob: Blob, project: Project, isInFolder: Bool) -> some View {
        Button { store.printBlob(blobID: blob.id, in: project.id) } label: {
            Label("Print...", systemImage: "printer")
        }
        if isInFolder {
            Button { store.moveBlobToRoot(blob.id, in: project.id) } label: {
                Label("Send Back to Root", systemImage: "arrow.up")
            }
        }
        Divider()
        Button(role: .destructive) { store.deleteBlob(blob.id, in: project.id) } label: {
            Label("Delete Blob", systemImage: "trash")
        }
    }
}

// MARK: - BlobTreeRow

private struct BlobTreeRow: View {
    @EnvironmentObject var store: ProjectStore
    @EnvironmentObject var appColors: AppColors
    let blob: Blob
    let projectID: UUID
    let isActive: Bool
    let isGlowing: Bool
    let glowOpacity: Double
    let indent: CGFloat
    @State private var title: String?
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "doc.text")
                .font(.system(size: 10))
                .foregroundColor(AppColors.shared.textResting)
            Text(title ?? "Untitled")
                .font(.system(size: 12))
                .foregroundColor(AppColors.shared.textResting)
                .lineLimit(1)
            Spacer()
        }
        .padding(.leading, indent).padding(.trailing, 8).padding(.vertical, 4)
        .background(isActive ? AppColors.shared.surfaceRaised.opacity(0.5) : isHovered ? AppColors.shared.surfaceRaised.opacity(0.25) : Color.clear)
        .overlay(
            isActive
                ? Rectangle().frame(width: 4)
                .foregroundColor(AppColors.shared.textHeading)
                .opacity(0.7)
                : nil,
            alignment: .leading
        )
        .overlay(isGlowing
            ? RoundedRectangle(cornerRadius: 4)
                .fill(AppColors.shared.metaConfirmation.opacity(glowOpacity * 0.3))
            : nil)
        .onHover { isHovered = $0 }
        .task(id: blob) {
            let result = await Task.detached(priority: .utility) {
                await store.loadBlobExcerpt(blobID: blob.id, in: projectID)
            }.value
            title = result.title ?? result.body.flatMap { String($0.prefix(40)) }
        }
    }
}

// MARK: - BlobDragPreview

private struct BlobDragPreview: View {
    @EnvironmentObject var store: ProjectStore
    let blob: Blob
    let projectID: UUID
    @State private var title: String?

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "doc.text").font(.system(size: 10))
                .foregroundColor(AppColors.shared.textHeading)
            Text(title ?? "Untitled").font(.system(size: 12)).lineLimit(1)
                .foregroundColor(AppColors.shared.textHeading)
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(AppColors.shared.surface)
        .cornerRadius(5)
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(AppColors.shared.borderCard, lineWidth: 1))
        .frame(width: 160, alignment: .leading)
        .task {
            let result = await Task.detached(priority: .utility) {
                await store.loadBlobExcerpt(blobID: blob.id, in: projectID)
            }.value
            title = result.title ?? result.body.flatMap { String($0.prefix(40)) }
        }
    }
}

#Preview {
    FileNavigatorView(
        selectedProjectID: .constant(nil),
        activeBlobID: .constant(nil),
        expandedFolderIDs: .constant([]),
        selectedFolderID: .constant(nil)
    )
    .environmentObject(ProjectStore())
    .environmentObject(AppColors.shared)
    .frame(width: 270)
}
