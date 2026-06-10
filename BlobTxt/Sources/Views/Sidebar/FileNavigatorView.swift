import SwiftUI

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
                            onOpen: openBlob,
                            onToggle: toggleFolder,
                            onStartRename: startRename,
                            onCommitRename: commitRename,
                            onCancelRename: cancelRename,
                            onDelete: requestDelete
                        )
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)
            }

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

// MARK: - Recursive tree rows

// Renders a list of sibling nodes at a given depth, recursing into expanded folders.
private struct NodeRowsView: View {
    let nodes: [FileNode]
    let depth: Int
    @ObservedObject var model: NavigatorModel
    let activeEditorURL: URL?
    let renamingURL: URL?
    @Binding var renameDraft: String
    let onOpen: (URL) -> Void
    let onToggle: (FileNode) -> Void
    let onStartRename: (FileNode) -> Void
    let onCommitRename: (FileNode) -> Void
    let onCancelRename: () -> Void
    let onDelete: (FileNode) -> Void

    var body: some View {
        ForEach(nodes) { node in
            FileRowView(
                node: node,
                depth: depth,
                isExpanded: model.isExpanded(node),
                isSelected: !node.isDirectory && activeEditorURL == node.url,
                isRenaming: sameFile(renamingURL, node.url),
                renameDraft: $renameDraft,
                onTap: {
                    if node.isDirectory { onToggle(node) } else { onOpen(node.url) }
                },
                onStartRename: { onStartRename(node) },
                onCommitRename: { onCommitRename(node) },
                onCancelRename: onCancelRename,
                onDelete: { onDelete(node) }
            )

            if node.isDirectory && model.isExpanded(node) {
                NodeRowsView(
                    nodes: node.children,
                    depth: depth + 1,
                    model: model,
                    activeEditorURL: activeEditorURL,
                    renamingURL: renamingURL,
                    renameDraft: $renameDraft,
                    onOpen: onOpen,
                    onToggle: onToggle,
                    onStartRename: onStartRename,
                    onCommitRename: onCommitRename,
                    onCancelRename: onCancelRename,
                    onDelete: onDelete
                )
            }
        }
    }
}

// A single navigator row. Folders lead with a chevron, blobs with a file icon.
// The whole row is the tap target. The trailing Spacer reserves room for a future
// right-end indicator. An open blob keeps the metaIndication overlay.
private struct FileRowView: View {
    @EnvironmentObject var appColors: AppColors

    let node: FileNode
    let depth: Int
    let isExpanded: Bool
    let isSelected: Bool
    let isRenaming: Bool
    @Binding var renameDraft: String
    let onTap: () -> Void
    let onStartRename: () -> Void
    let onCommitRename: () -> Void
    let onCancelRename: () -> Void
    let onDelete: () -> Void

    @FocusState private var fieldFocused: Bool

    private let indentStep: CGFloat = 12

    var body: some View {
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
        .background(isSelected ? appColors.metaIndication.opacity(0.08) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { if !isRenaming { onTap() } }
        .contextMenu {
            Button("Rename", action: onStartRename)
            Button("Delete", role: .destructive, action: onDelete)
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
