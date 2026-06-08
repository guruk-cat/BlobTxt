import SwiftUI

struct FileNavigatorView: View {
    @EnvironmentObject var store: ProjectStore
    @EnvironmentObject var appColors: AppColors
    @Binding var activeBlobURL: URL?
    @Binding var expandedFolderURLs: Set<URL>
    @Binding var selectedFolderURL: URL?

    @State private var isRenamingBlob = false
    @State private var renameBlobURL: URL?
    @State private var renameBlobText = ""
    @State private var isRenamingFolder = false
    @State private var renameFolderURL: URL?
    @State private var renameFolderText = ""
    @State private var hoverNewFolder = false
    @State private var hoverNewBlob = false
    @State private var refreshToken: UUID = UUID()  // bumped after any CRUD to force re-read

    static let rowHeight: CGFloat = 26

    var body: some View {
        if let project = store.currentProject {
            projectView(project)
                .onChange(of: store.currentProject) { _ in expandedFolderURLs = []; selectedFolderURL = nil }
        } else {
            Color.clear
        }
    }

    // MARK: - Project view

    @ViewBuilder
    private func projectView(_ project: Project) -> some View {
        let (blobs, folders) = store.contentsOfDirectory(url: project.url)
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                headerRow(project: project, directoryURL: project.url, folders: folders)
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(folders, id: \.path) { folder in folderRow(folder) }
                    ForEach(blobs) { blob in blobRow(blob, indent: 26) }
                }
                .padding(.bottom, 60)
            }
        }
        .id(refreshToken)
        .alert("Rename", isPresented: $isRenamingBlob) {
            TextField("File name", text: $renameBlobText)
            Button("Cancel", role: .cancel) {}
            Button("Rename") {
                if let url = renameBlobURL {
                    let newURL = store.renameBlob(at: url, to: renameBlobText)
                    if activeBlobURL == url { activeBlobURL = newURL }
                    refreshToken = UUID()
                }
            }
        }
        .alert("Rename Folder", isPresented: $isRenamingFolder) {
            TextField("Folder name", text: $renameFolderText)
            Button("Cancel", role: .cancel) {}
            Button("Rename") {
                if let url = renameFolderURL {
                    let newURL = store.renameFolder(at: url, to: renameFolderText)
                    if expandedFolderURLs.contains(url) {
                        expandedFolderURLs.remove(url); expandedFolderURLs.insert(newURL)
                    }
                    if selectedFolderURL == url { selectedFolderURL = newURL }
                    refreshToken = UUID()
                }
            }
        }
    }

    // MARK: - Header row

    private func headerRow(project: Project, directoryURL: URL, folders: [URL]) -> some View {
        HStack(spacing: 6) {
            Text(project.name.uppercased())
                .font(.system(size: 11, weight: .semibold)).tracking(0.5)
                .foregroundColor(AppColors.shared.textHeading)
            Spacer()
            Button {
                let url = store.createFolder(in: directoryURL, name: "Untitled Folder")
                expandedFolderURLs.insert(url); selectedFolderURL = url; refreshToken = UUID()
            } label: {
                Image(systemName: "folder.badge.plus").font(.system(size: 11, weight: .semibold))
                    .foregroundColor(hoverNewFolder ? AppColors.shared.textBody : AppColors.shared.textMuted)
            }
            .buttonStyle(.plain).onHover { hoverNewFolder = $0 }.padding(.trailing, 4)

            Button {
                let blob = store.createBlob(in: selectedFolderURL ?? directoryURL)
                activeBlobURL = blob.url; refreshToken = UUID()
            } label: {
                Image(systemName: "doc.badge.plus").font(.system(size: 11, weight: .semibold))
                    .foregroundColor(hoverNewBlob ? AppColors.shared.textBody : AppColors.shared.textMuted)
            }
            .buttonStyle(.plain).onHover { hoverNewBlob = $0 }
        }
        .padding(.leading, 12).padding(.trailing, 8).padding(.top, 12).padding(.bottom, 4)
    }

    // MARK: - Folder row

    @ViewBuilder
    private func folderRow(_ folder: URL) -> some View {
        let expanded = expandedFolderURLs.contains(folder)
        let (folderBlobs, _) = store.contentsOfDirectory(url: folder)
        let isSelected = selectedFolderURL == folder && activeBlobURL == nil

        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Image(systemName: "folder.fill").font(.system(size: 11)).foregroundColor(AppColors.shared.textResting)
                Text(folder.lastPathComponent).font(.system(size: 12)).foregroundColor(AppColors.shared.textResting).lineLimit(1)
                Spacer()
            }
            .padding(.leading, 26).padding(.trailing, 8).padding(.vertical, 4)
            .overlay(alignment: .leading) {
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(!folderBlobs.isEmpty ? AppColors.shared.textResting : Color.clear)
                    .frame(width: 14).padding(.leading, 8)
            }
            .frame(height: Self.rowHeight)
            .background(isSelected ? AppColors.shared.surfaceRaised.opacity(0.5) : Color.clear)
            .contentShape(Rectangle())
            .onTapGesture {
                if expanded { expandedFolderURLs.remove(folder); selectedFolderURL = nil }
                else { expandedFolderURLs.insert(folder); selectedFolderURL = folder }
            }
            .contextMenu { folderContextMenu(folder) }

            if expanded {
                ForEach(folderBlobs) { blob in blobRow(blob, indent: 42) }
            }
        }
    }

    // MARK: - Blob row

    private func blobRow(_ blob: Blob, indent: CGFloat) -> some View {
        BlobTreeRow(blob: blob, isActive: activeBlobURL == blob.url, indent: indent)
            .frame(height: Self.rowHeight)
            .contentShape(Rectangle())
            .onTapGesture { activeBlobURL = blob.url; selectedFolderURL = nil }
            .contextMenu { blobContextMenu(blob) }
    }

    // MARK: - Context menus

    @ViewBuilder
    private func blobContextMenu(_ blob: Blob) -> some View {
        Button { store.printBlob(at: blob.url) } label: { Label("Print…", systemImage: "printer") }
        Divider()
        Button {
            renameBlobURL = blob.url
            renameBlobText = blob.displayName
            isRenamingBlob = true
        } label: { Label("Rename", systemImage: "pencil") }
        Divider()
        Button(role: .destructive) {
            if activeBlobURL == blob.url { activeBlobURL = nil }
            store.deleteBlob(at: blob.url)
            refreshToken = UUID()
        } label: { Label("Delete", systemImage: "trash") }
    }

    @ViewBuilder
    private func folderContextMenu(_ folder: URL) -> some View {
        Button {
            renameFolderURL = folder
            renameFolderText = folder.lastPathComponent
            isRenamingFolder = true
        } label: { Label("Rename Folder", systemImage: "pencil") }
        Divider()
        Button(role: .destructive) {
            store.deleteFolder(at: folder)
            expandedFolderURLs.remove(folder)
            if selectedFolderURL == folder { selectedFolderURL = nil }
            refreshToken = UUID()
        } label: { Label("Delete Folder", systemImage: "trash") }
    }
}

// MARK: - BlobTreeRow

private struct BlobTreeRow: View {
    @EnvironmentObject var store: ProjectStore
    @EnvironmentObject var appColors: AppColors
    let blob: Blob
    let isActive: Bool
    let indent: CGFloat
    @State private var title: String?
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "doc.text").font(.system(size: 10)).foregroundColor(AppColors.shared.textResting)
            Text(title ?? blob.displayName).font(.system(size: 12)).foregroundColor(AppColors.shared.textResting).lineLimit(1)
            Spacer()
        }
        .padding(.leading, indent).padding(.trailing, 8).padding(.vertical, 4)
        .background(isActive ? AppColors.shared.surfaceRaised.opacity(0.5) : isHovered ? AppColors.shared.surfaceRaised.opacity(0.25) : Color.clear)
        .overlay(isActive ? Rectangle().frame(width: 4).foregroundColor(AppColors.shared.textHeading).opacity(0.7) : nil, alignment: .leading)
        .onHover { isHovered = $0 }
        .task(id: blob.url) {
            let excerpt = await Task.detached(priority: .utility) {
                store.loadBlobExcerpt(at: blob.url)
            }.value
            title = excerpt.title ?? excerpt.body.map { String($0.prefix(40)) }
        }
    }
}

#Preview {
    FileNavigatorView(
        activeBlobURL: .constant(nil),
        expandedFolderURLs: .constant([]),
        selectedFolderURL: .constant(nil)
    )
    .environmentObject(ProjectStore())
    .environmentObject(AppColors.shared)
    .frame(width: 270)
}
