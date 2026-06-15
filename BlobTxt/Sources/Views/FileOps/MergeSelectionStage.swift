import SwiftUI

// The first MB stage. Left pane: a read-only navigator (folders expand/collapse; blobs are draggable
// but nothing can be created, renamed, or deleted). Right pane: the drop zone, a numbered ordered
// list of the chosen blobs.
//
// Drag-and-drop reuses the navigator's mechanism — a manual `DragGesture` in one shared coordinate
// space, with row/zone frames tracked through preferences. Three interactions run through it:
//   - drag a blob from the tree into the zone to add it,
//   - drag a zone row to reorder it,
//   - drag a zone row out of the zone to remove it.
struct MergeSelectionStage: View {
    @EnvironmentObject var store: ProjectStore
    @EnvironmentObject var appColors: AppColors
    @ObservedObject var navigator: NavigatorModel
    @ObservedObject var session: MergeSession

    private enum DragOrigin { case none, tree, zone }

    // Drag state. `dragURL` is the blob in flight; `dragOrigin` says which pane it came from.
    @State private var dragURL: URL?
    @State private var dragName = ""
    @State private var dragOrigin: DragOrigin = .none
    @State private var dragLocation: CGPoint = .zero

    // Tracked frames, in `mbSpace`: the whole drop-zone pane (inside/outside tests) and each zone row
    // (insertion-point math). `insertionIndex` is the gap the drop would land in, nil when the cursor
    // is outside the zone.
    @State private var zoneFrame: CGRect = .zero
    @State private var zoneRowFrames: [URL: CGRect] = [:]
    @State private var insertionIndex: Int? = nil

    // Insets so the scroll content clears the panel's stage title (top) and footer (bottom), both of
    // which are drawn over this stage by `MergeBlobsPanel`.
    private let topInset: CGFloat = 44
    private let bottomInset: CGFloat = 56

    var body: some View {
        HStack(spacing: 0) {
            navigatorPane
                .frame(maxWidth: MergeBlobsPanel.selectionColumnWidth, maxHeight: .infinity)
                .background(appColors.uiPanel)
            dropZonePane
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(appColors.surface)
        }
        .coordinateSpace(name: mbSpace)
        .onPreferenceChange(ZoneFrameKey.self) { zoneFrame = $0 }
        .onPreferenceChange(ZoneRowFramesKey.self) { zoneRowFrames = $0 }
        .overlay(dragPreview)
        .onAppear {
            if let url = store.currentProject?.url { navigator.activate(projectURL: url) }
        }
    }

    // MARK: - Left pane: read-only navigator

    private var navigatorPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(visibleRows()) { row in
                    treeRow(row.node, depth: row.depth)
                }
            }
            .padding(.top, topInset)
            .padding(.bottom, bottomInset)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // A flattened tree row: a node and its indent depth.
    private struct VisibleRow: Identifiable {
        let node: FileNode
        let depth: Int
        var id: URL { node.url }
    }

    // Depth-first flatten of the tree honoring expanded folders. Folders and `.md` blobs only; other
    // file types are hidden, since only blobs can be merged.
    private func visibleRows() -> [VisibleRow] {
        var out: [VisibleRow] = []
        func walk(_ nodes: [FileNode], _ depth: Int) {
            for node in nodes {
                if node.isDirectory {
                    out.append(VisibleRow(node: node, depth: depth))
                    if navigator.isExpanded(node) { walk(node.children, depth + 1) }
                } else if node.url.isBlobFile {
                    out.append(VisibleRow(node: node, depth: depth))
                }
            }
        }
        walk(navigator.rootNodes, 0)
        return out
    }

    @ViewBuilder
    private func treeRow(_ node: FileNode, depth: Int) -> some View {
        if node.isDirectory {
            folderRow(node, depth: depth)
        } else {
            blobRow(node, depth: depth)
        }
    }

    private func folderRow(_ node: FileNode, depth: Int) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(appColors.uiTextResting)
                .rotationEffect(.degrees(navigator.isExpanded(node) ? 90 : 0))
                .frame(width: 12, alignment: .center)
            Text(node.name)
                .font(.system(size: 12))
                .foregroundColor(appColors.uiTextResting)
                .lineLimit(1)
            Spacer(minLength: 4)
        }
        .padding(.leading, 6 + CGFloat(depth) * 12)
        .padding(.trailing, 6)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { navigator.toggle(node) }
    }

    @ViewBuilder
    private func blobRow(_ node: FileNode, depth: Int) -> some View {
        let already = session.contains(node.url)
        let row = HStack(spacing: 5) {
            Image(systemName: "doc.text")
                .font(.system(size: 10))
                .foregroundColor(already ? appColors.uiTextMuted : appColors.uiTextResting)
                .frame(width: 12, alignment: .center)
            Text(MergeSession.displayName(for: node.url))
                .font(.system(size: 12))
                .foregroundColor(already ? appColors.uiTextMuted : appColors.uiTextResting)
                .lineLimit(1)
            Spacer(minLength: 4)
            if already {
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(appColors.uiConfirmation)
            }
        }
        .padding(.leading, 6 + CGFloat(depth) * 12)
        .padding(.trailing, 6)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .opacity(dragURL == node.url && dragOrigin == .tree ? 0.4 : 1)
        .contentShape(Rectangle())

        // An already-selected blob is not draggable again; the zone is where it lives now.
        if already {
            row
        } else {
            row.simultaneousGesture(treeDrag(node))
        }
    }

    // MARK: - Right pane: drop zone

    private var dropZonePane: some View {
        Group {
            if session.selected.isEmpty {
                emptyZone
            } else {
                zoneList
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Track the whole pane's frame so the cursor can be tested inside/outside the zone.
        .background(
            GeometryReader { geo in
                Color.clear.preference(key: ZoneFrameKey.self, value: geo.frame(in: .named(mbSpace)))
            }
        )
        // Highlight the zone while a tree blob is dragged over it.
        .overlay(
            RoundedRectangle(cornerRadius: 0)
                .stroke(appColors.metaIndication, lineWidth: 2)
                .opacity(dragOrigin == .tree && insertionIndex != nil ? 0.6 : 0)
                .allowsHitTesting(false)
        )
    }

    private var emptyZone: some View {
        VStack {
            Spacer()
            Text("Drag blobs here to merge them.")
                .font(.system(size: 13))
                .foregroundColor(appColors.textMuted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var zoneList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(session.selected, id: \.self) { url in
                    let offset = session.selected.firstIndex(of: url) ?? 0
                    if insertionIndex == offset { insertionLine }
                    zoneRow(url: url, number: offset + 1)
                }
                if insertionIndex == session.selected.count { insertionLine }
            }
            .padding(.top, topInset)
            .padding(.bottom, bottomInset)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var insertionLine: some View {
        RoundedRectangle(cornerRadius: 1)
            .fill(appColors.metaIndication)
            .frame(height: 2)
            .frame(maxWidth: .infinity)
    }

    private func zoneRow(url: URL, number: Int) -> some View {
        let isDragged = dragURL == url && dragOrigin == .zone
        return HStack(spacing: 8) {
            Text("\(number)")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(appColors.textMuted)
                .frame(width: 18, alignment: .trailing)
            Image(systemName: "doc.text")
                .font(.system(size: 11))
                .foregroundColor(appColors.textResting)
            Text(MergeSession.displayName(for: url))
                .font(.system(size: 13))
                .foregroundColor(appColors.textBody)
                .lineLimit(1)
            Spacer(minLength: 4)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(appColors.surfaceSunken))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(appColors.border, lineWidth: 1))
        .opacity(isDragged ? 0.4 : 1)
        // Track this row's frame for insertion-point math.
        .background(
            GeometryReader { geo in
                Color.clear.preference(key: ZoneRowFramesKey.self, value: [url: geo.frame(in: .named(mbSpace))])
            }
        )
        .simultaneousGesture(zoneDrag(url))
    }

    // MARK: - Drag overlay

    @ViewBuilder
    private var dragPreview: some View {
        if dragURL != nil {
            HStack(spacing: 5) {
                Image(systemName: "doc.text")
                    .font(.system(size: 10))
                    .foregroundColor(appColors.textHeading)
                Text(dragName)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .foregroundColor(appColors.textHeading)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(appColors.surface)
            .cornerRadius(5)
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(appColors.border, lineWidth: 1))
            .frame(width: 160, alignment: .leading)
            .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
            .position(dragLocation)
            .allowsHitTesting(false)
        }
    }

    // MARK: - Drag gestures

    private func treeDrag(_ node: FileNode) -> some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .named(mbSpace))
            .onChanged { value in
                if dragURL == nil {
                    dragURL = node.url
                    dragName = MergeSession.displayName(for: node.url)
                    dragOrigin = .tree
                }
                guard dragOrigin == .tree, dragURL == node.url else { return }
                dragLocation = value.location
                insertionIndex = zoneFrame.contains(value.location) ? dropIndex(forY: value.location.y) : nil
            }
            .onEnded { _ in
                defer { clearDrag() }
                guard dragOrigin == .tree, let url = dragURL else { return }
                if zoneFrame.contains(dragLocation) {
                    session.insert(url, at: insertionIndex ?? session.selected.count)
                }
            }
    }

    private func zoneDrag(_ url: URL) -> some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .named(mbSpace))
            .onChanged { value in
                if dragURL == nil {
                    dragURL = url
                    dragName = MergeSession.displayName(for: url)
                    dragOrigin = .zone
                }
                guard dragOrigin == .zone, dragURL == url else { return }
                dragLocation = value.location
                insertionIndex = zoneFrame.contains(value.location) ? dropIndex(forY: value.location.y) : nil
            }
            .onEnded { _ in
                defer { clearDrag() }
                guard dragOrigin == .zone, let url = dragURL else { return }
                if zoneFrame.contains(dragLocation), let visual = insertionIndex {
                    // `dropIndex` counts the dragged row too; account for its removal when it sits
                    // above the drop point.
                    let current = session.selected.firstIndex(of: url) ?? 0
                    session.reorder(url, to: current < visual ? visual - 1 : visual)
                } else {
                    session.remove(url)
                }
            }
    }

    // The gap index (0...count) the cursor's y falls into, counting every current row.
    private func dropIndex(forY y: CGFloat) -> Int {
        for (i, url) in session.selected.enumerated() {
            guard let rect = zoneRowFrames[url] else { continue }
            if y < rect.midY { return i }
        }
        return session.selected.count
    }

    private func clearDrag() {
        dragURL = nil
        dragName = ""
        dragOrigin = .none
        dragLocation = .zero
        insertionIndex = nil
    }
}

// Shared coordinate space for the selection stage; the drag location, zone frame, and row frames are
// all measured in it so they can be compared directly.
let mbSpace = "mbSelect"

private struct ZoneFrameKey: PreferenceKey {
    static var defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}

private struct ZoneRowFramesKey: PreferenceKey {
    static var defaultValue: [URL: CGRect] = [:]
    static func reduce(value: inout [URL: CGRect], nextValue: () -> [URL: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}
