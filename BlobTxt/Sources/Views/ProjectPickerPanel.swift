import SwiftUI

struct ProjectPickerPanel: View {
    @EnvironmentObject var store: ProjectStore
    @EnvironmentObject var appColors: AppColors
    @Binding var selectedProjectID: UUID?
    var onDismiss: () -> Void

    @State private var isCreatingProject = false
    @State private var newProjectName = ""
    @State private var plusButtonHovered = false
    @State private var dismissButtonHovered = false
    @State private var hoveredProjectID: UUID? = nil
    @State private var isRenamingProject = false
    @State private var renameProjectID: UUID?
    @State private var renameProjectText = ""

    private var allProjects: [Project] {
        store.projects.sorted { $0.createdAt < $1.createdAt }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("PROJECTS")
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.5)
                    .foregroundColor(AppColors.shared.textHeading)
                Spacer()
                Button {
                    newProjectName = ""
                    isCreatingProject = true
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(plusButtonHovered ? AppColors.shared.textHeading : AppColors.shared.textMuted)
                }
                .buttonStyle(.plain)
                .onHover { plusButtonHovered = $0 }
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 8)

            Divider()
                .padding(.horizontal, 16)

            // Project list
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(allProjects) { project in
                        projectRow(project)
                    }
                }
                .padding(.vertical, 8)
            }

            Divider()
                .padding(.horizontal, 16)

            // Footer close button
            HStack {
                Spacer()
                Button { onDismiss() }
                label: {
                    Text("Dismiss")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(dismissButtonHovered ? AppColors.shared.surface : AppColors.shared.textResting)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 8).fill(AppColors.shared.surfaceSunken)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(dismissButtonHovered ? AppColors.shared.metaIndication.opacity(0.9) : AppColors.shared.surfaceSunken)
                                )
                        )
                }
                .buttonStyle(.plain)
                .onHover { dismissButtonHovered = $0 }
                .padding(.vertical, 8)
                Spacer()
            }
        }
        .frame(width: 320, height: 400)
        .background(AppColors.shared.chromePanel)
        .alert("New Project", isPresented: $isCreatingProject) {
            TextField("Project name", text: $newProjectName)
            Button("Cancel", role: .cancel) {}
            Button("Create") {
                let name = newProjectName.trimmingCharacters(in: .whitespaces)
                let p = store.createProject(name: name.isEmpty ? "Untitled Project" : name)
                selectedProjectID = p.id
                onDismiss()
            }
        }
        .alert("Rename Project", isPresented: $isRenamingProject) {
            TextField("Project name", text: $renameProjectText)
            Button("Cancel", role: .cancel) {}
            Button("Rename") {
                if let id = renameProjectID {
                    store.renameProject(id, to: renameProjectText)
                }
            }
        }
    }

    @ViewBuilder
    private func projectRow(_ project: Project) -> some View {
        let isHovered = hoveredProjectID == project.id
        let isSelected = selectedProjectID == project.id

        HStack(spacing: 8) {
            Image(systemName: "folder")
                .font(.system(size: 13))
                .foregroundColor(isSelected ? AppColors.shared.metaIndication : AppColors.shared.textResting)
            Text(project.name)
                .font(.system(size: 13))
                .foregroundColor(isSelected ? AppColors.shared.metaIndication : AppColors.shared.textResting)
                .lineLimit(1)
            Spacer()
            if isSelected {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(AppColors.shared.metaIndication)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
        .background(isHovered ? AppColors.shared.surfaceRaised.opacity(0.3) : Color.clear)
        .contentShape(Rectangle())
        .onHover { hoveredProjectID = $0 ? project.id : (hoveredProjectID == project.id ? nil : hoveredProjectID) }
        .onTapGesture {
            selectedProjectID = project.id
            onDismiss()
        }
        .contextMenu {
            Button {
                renameProjectID = project.id
                renameProjectText = project.name
                isRenamingProject = true
            } label: { Label("Rename", systemImage: "pencil") }
            Divider()
            Button(role: .destructive) {
                store.deleteProject(project.id)
                if selectedProjectID == project.id {
                    selectedProjectID = nil
                }
            } label: { Label("Delete Project", systemImage: "trash") }
        }
    }
}

#Preview {
    ProjectPickerPanel(selectedProjectID: .constant(nil), onDismiss: {})
        .environmentObject(ProjectStore())
        .environmentObject(AppColors.shared)
}
