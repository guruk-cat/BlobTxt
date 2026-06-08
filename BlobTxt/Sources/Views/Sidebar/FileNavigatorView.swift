import SwiftUI

// A single .md file found anywhere in the project directory tree.
private struct MDFileEntry: Identifiable {
    let id = UUID()
    let displayName: String     // filename without the .md extension
    let parentDirName: String?  // immediate parent directory name, nil if file is at project root
    let url: URL
}

struct FileNavigatorView: View {
    @EnvironmentObject var store: ProjectStore
    @EnvironmentObject var appColors: AppColors
    @Binding var activeEditorURL: URL?

    @State private var entries: [MDFileEntry] = []

    var body: some View {
        if let project = store.currentProject {
            projectView(project: project)
                .onChange(of: store.currentProject?.url) { _ in reload() }
        } else {
            Color.clear
        }
    }

    // MARK: - Project view

    private func projectView(project: Project) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                headerRow(project: project)
                entriesContent
            }
            .padding(.bottom, 60)
        }
        .onAppear { reload() }
    }

    // Project name header
    private func headerRow(project: Project) -> some View {
        HStack {
            Text(project.name.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.5)
                .foregroundColor(AppColors.shared.textHeading)
            Spacer()
        }
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .padding(.top, 12)
        .padding(.bottom, 4)
    }

    // File list or empty state
    @ViewBuilder
    private var entriesContent: some View {
        if entries.isEmpty {
            Text("No documents.")
                .font(.system(size: 12))
                .foregroundColor(AppColors.shared.textMuted)
                .padding(.leading, 12)
                .padding(.trailing, 8)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            ForEach(entries) { entry in
                entryRow(entry)
            }
        }
    }

    // Single file row: primary filename, optional parent directory below it.
    // Tapping the row sets `activeEditorURL` to open the file in the editor.
    private func entryRow(_ entry: MDFileEntry) -> some View {
        let isSelected = activeEditorURL == entry.url

        return VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                Image(systemName: "doc.text")
                    .font(.system(size: 10))
                    .foregroundColor(isSelected ? AppColors.shared.metaIndication : AppColors.shared.textResting)
                Text(entry.displayName)
                    .font(.system(size: 12))
                    .foregroundColor(isSelected ? AppColors.shared.metaIndication : AppColors.shared.textResting)
                    .lineLimit(1)
                Spacer()
            }
            if let dir = entry.parentDirName {
                Text(dir)
                    .font(.system(size: 10))
                    .foregroundColor(AppColors.shared.textMuted)
                    .lineLimit(1)
                    .padding(.leading, 18)
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? AppColors.shared.metaIndication.opacity(0.08) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { activeEditorURL = entry.url }
    }

    // MARK: - Data loading

    // Scans the current project directory recursively for .md files and rebuilds `entries`.
    // Hidden files and non-.md items are excluded by the enumerator options and suffix check.
    private func reload() {
        guard let projectURL = store.currentProject?.url else { entries = []; return }
        let fm = FileManager.default

        guard let enumerator = fm.enumerator(
            at: projectURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            entries = []
            return
        }

        var found: [MDFileEntry] = []
        for case let fileURL as URL in enumerator {
            let filename = fileURL.lastPathComponent
            guard filename.hasSuffix(".md") else { continue }

            let parentURL = fileURL.deletingLastPathComponent()
            let isAtRoot = parentURL.standardized.path == projectURL.standardized.path
            let parentDirName = isAtRoot ? nil : parentURL.lastPathComponent

            let displayName = String(filename.dropLast(3))
            found.append(MDFileEntry(displayName: displayName, parentDirName: parentDirName, url: fileURL))
        }

        entries = found.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }
}

#Preview {
    FileNavigatorView(activeEditorURL: .constant(nil))
        .environmentObject(ProjectStore())
        .environmentObject(AppColors.shared)
        .frame(width: 270)
}
