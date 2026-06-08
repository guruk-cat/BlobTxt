import SwiftUI

class ProjectStore: ObservableObject {
    @Published var projects: [Project] = []

    var blobScrollPositions: [UUID: Int] = [:] // keyed by blobID; not persisted

    private let fileManager = FileManager.default
    private let rootPath: String

    init() {
        self.rootPath = NSHomeDirectory() + "/Documents/BlobTxt"
        ensureRootDirectory()
        loadProjects()
    }

    // MARK: - Initialization

    private func ensureRootDirectory() {
        if !fileManager.fileExists(atPath: rootPath) {
            try? fileManager.createDirectory(
                atPath: rootPath,
                withIntermediateDirectories: true,
                attributes: nil
            )
        }
    }

    private func loadProjects() {
        guard fileManager.fileExists(atPath: rootPath) else { return }

        guard let contents = try? fileManager.contentsOfDirectory(atPath: rootPath) else { return }

        var loadedProjects: [Project] = []
        for item in contents {
            let itemPath = rootPath + "/" + item
            var isDir: ObjCBool = false
            guard fileManager.fileExists(atPath: itemPath, isDirectory: &isDir), isDir.boolValue else {
                continue
            }

            let projectFile = itemPath + "/project.json"
            guard fileManager.fileExists(atPath: projectFile) else { continue }

            do {
                let data = try Data(contentsOf: URL(fileURLWithPath: projectFile))
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                let project = try decoder.decode(Project.self, from: data)
                loadedProjects.append(project)
            } catch {
                print("Failed to load project at \(projectFile): \(error)")
            }
        }

        loadedProjects.sort { $0.createdAt < $1.createdAt }
        DispatchQueue.main.async {
            self.projects = loadedProjects
        }
    }

    // MARK: - Project CRUD

    func createProject(name: String) -> Project {
        let project = Project(name: name)
        let projectPath = rootPath + "/" + project.id.uuidString
        do {
            try fileManager.createDirectory(
                atPath: projectPath,
                withIntermediateDirectories: true,
                attributes: nil
            )
        } catch {
            print("Failed to create project directory: \(error)")
            return project
        }

        save(project)
        DispatchQueue.main.async {
            self.projects.append(project)
            self.projects.sort { $0.createdAt < $1.createdAt }
        }
        return project
    }

    func deleteProject(_ projectID: UUID) {
        let projectPath = rootPath + "/" + projectID.uuidString
        do {
            try fileManager.removeItem(atPath: projectPath)
        } catch {
            print("Failed to delete project directory: \(error)")
        }

        DispatchQueue.main.async {
            self.projects.removeAll { $0.id == projectID }
        }
    }

    func renameProject(_ projectID: UUID, to name: String) {
        mutateProject(projectID) { project in
            project.name = name
        }
    }

    // MARK: - Folder CRUD

    func createFolder(in projectID: UUID, name: String) -> BlobFolder {
        guard let projectIndex = projectIndex(projectID) else { return BlobFolder(name: name) }

        var project = projects[projectIndex]
        var folder = BlobFolder(name: name)
        // Below the current minimum so the new folder appears first; rebuildRootSortOrders normalizes to 0-based indices.
        folder.sortOrder = (project.folders.min { $0.sortOrder < $1.sortOrder }?.sortOrder ?? 0) - 1
        project.folders.append(folder)
        rebuildRootSortOrders(&project)

        updateProject(project)
        return folder
    }

    func deleteFolder(_ folderID: UUID, in projectID: UUID) {
        guard let projectIndex = projectIndex(projectID) else { return }

        var project = projects[projectIndex]

        project.folders.removeAll { $0.id == folderID }

        // Delete blob files from disk before removing from project
        let blobsInFolder = project.blobs.filter { $0.folderID == folderID }
        let projectPath = rootPath + "/" + projectID.uuidString
        for blob in blobsInFolder {
            let blobFile = projectPath + "/" + blob.id.uuidString + ".json"
            try? fileManager.removeItem(atPath: blobFile)
        }

        project.blobs.removeAll { $0.folderID == folderID }

        updateProject(project)
    }

    func renameFolder(_ folderID: UUID, in projectID: UUID, to name: String) {
        guard let projectIndex = projectIndex(projectID) else { return }

        var project = projects[projectIndex]

        if let index = project.folders.firstIndex(where: { $0.id == folderID }) {
            project.folders[index].name = name
        }

        updateProject(project)
    }

    // MARK: - Blob CRUD

    func createBlob(in projectID: UUID, folderID: UUID? = nil) -> Blob {
        guard let projectIndex = projectIndex(projectID) else { return Blob() }

        var project = projects[projectIndex]
        let blob = Blob(folderID: folderID)

        if let folderID = folderID {
            // Insert before first existing blob in folder
            let firstFolderSortOrder = project.blobs
                .filter { $0.folderID == folderID }
                .min { $0.sortOrder < $1.sortOrder }?
                .sortOrder ?? 0
            var newBlob = blob
            newBlob.sortOrder = firstFolderSortOrder - 1
            project.blobs.append(newBlob)
            rebuildFolderSortOrders(&project, folderID: folderID)
        } else {
            // Insert before first existing root blob
            let firstRootBlobSortOrder = project.blobs
                .filter { $0.folderID == nil }
                .min { $0.sortOrder < $1.sortOrder }
                .map { $0.sortOrder }

            if let firstSortOrder = firstRootBlobSortOrder {
                var newBlob = blob
                newBlob.sortOrder = firstSortOrder - 1
                project.blobs.append(newBlob)
                rebuildRootSortOrders(&project)
            } else {
                let maxSortOrder = project.blobs
                    .filter { $0.folderID == nil }
                    .max { $0.sortOrder < $1.sortOrder }?
                    .sortOrder ?? -1
                var newBlob = blob
                newBlob.sortOrder = maxSortOrder + 1
                project.blobs.append(newBlob)
            }
        }

        updateProject(project)
        return blob
    }

    func deleteBlob(_ blobID: UUID, in projectID: UUID) {
        guard let projectIndex = projectIndex(projectID) else { return }

        var project = projects[projectIndex]

        if let blobIndex = project.blobs.firstIndex(where: { $0.id == blobID }) {
            let blob = project.blobs[blobIndex]
            let folderID = blob.folderID

            project.blobs.remove(at: blobIndex)

            // Delete blob file from disk
            let projectPath = rootPath + "/" + projectID.uuidString
            let blobFile = projectPath + "/" + blobID.uuidString + ".json"
            try? fileManager.removeItem(atPath: blobFile)

            // Rebuild sort orders for affected context
            if let folderID = folderID {
                rebuildFolderSortOrders(&project, folderID: folderID)
            } else {
                rebuildRootSortOrders(&project)
            }
        }

        updateProject(project)
    }

    func moveBlobToRoot(_ blobID: UUID, in projectID: UUID) {
        guard let projectIndex = projectIndex(projectID) else { return }

        var project = projects[projectIndex]

        if let index = project.blobs.firstIndex(where: { $0.id == blobID }) {
            let oldFolderID = project.blobs[index].folderID
            project.blobs[index].folderID = nil

            // Assign sortOrder before first existing root blob
            let firstRootBlobSortOrder = project.blobs
                .filter { $0.folderID == nil && $0.id != blobID }
                .min { $0.sortOrder < $1.sortOrder }
                .map { $0.sortOrder }

            if let firstSortOrder = firstRootBlobSortOrder {
                project.blobs[index].sortOrder = firstSortOrder - 1
            } else {
                let maxSortOrder = project.blobs
                    .filter { $0.folderID == nil }
                    .max { $0.sortOrder < $1.sortOrder }?
                    .sortOrder ?? -1
                project.blobs[index].sortOrder = maxSortOrder + 1
            }

            // Rebuild sort orders for both contexts
            if let oldFolderID = oldFolderID {
                rebuildFolderSortOrders(&project, folderID: oldFolderID)
            }
            rebuildRootSortOrders(&project)
        }

        updateProject(project)
    }

    // MARK: - Sort Order Management

    func rebuildSortOrders(in projectID: UUID, context folderID: UUID?) {
        guard let projectIndex = projectIndex(projectID) else { return }

        var project = projects[projectIndex]

        if let folderID = folderID {
            rebuildFolderSortOrders(&project, folderID: folderID)
        } else {
            rebuildRootSortOrders(&project)
        }

        updateProject(project)
    }

    func moveItem(in projectID: UUID, fromIndex: Int, toIndex: Int, context folderID: UUID?) {
        guard let projectIndex = projectIndex(projectID) else { return }
        guard fromIndex != toIndex else { return }

        var project = projects[projectIndex]

        if let folderID = folderID {
            // Folder context: all items are blobs; fromIndex/toIndex are 0-based within this folder's visible blobs
            var blobs = project.blobs
                .filter { $0.folderID == folderID }
                .sorted { $0.sortOrder < $1.sortOrder }
            guard fromIndex >= 0, fromIndex < blobs.count,
                  toIndex >= 0, toIndex < blobs.count else { return }
            let moved = blobs.remove(at: fromIndex)
            blobs.insert(moved, at: toIndex)
            // Write new sort orders directly — don't call rebuildFolderSortOrders which would
            // re-sort by the old (unchanged) sortOrder values and undo the move.
            for (i, blob) in blobs.enumerated() {
                if let idx = project.blobs.firstIndex(where: { $0.id == blob.id }) {
                    project.blobs[idx].sortOrder = i
                }
            }
        } else {
            // Root context: fromIndex/toIndex into folders-first ordering (folders, then root blobs)
            let sortedFolders = project.folders.sorted { $0.sortOrder < $1.sortOrder }
            let sortedRootBlobs = project.blobs
                .filter { $0.folderID == nil }
                .sorted { $0.sortOrder < $1.sortOrder }
            let folderCount = sortedFolders.count

            if fromIndex < folderCount {
                // Moving a folder; toIndex must also be within the folder section
                guard toIndex >= 0, toIndex < folderCount else { return }
                var folders = sortedFolders
                let moved = folders.remove(at: fromIndex)
                folders.insert(moved, at: toIndex)
                for (i, folder) in folders.enumerated() {
                    if let idx = project.folders.firstIndex(where: { $0.id == folder.id }) {
                        project.folders[idx].sortOrder = i
                    }
                }
            } else {
                // Moving a root blob; convert from allDashItems-space to blob-section-space
                let blobFromIndex = fromIndex - folderCount
                let blobToIndex   = toIndex   - folderCount
                guard blobFromIndex >= 0, blobFromIndex < sortedRootBlobs.count,
                      blobToIndex   >= 0, blobToIndex   < sortedRootBlobs.count else { return }
                var blobs = sortedRootBlobs
                let moved = blobs.remove(at: blobFromIndex)
                blobs.insert(moved, at: blobToIndex)
                for (i, blob) in blobs.enumerated() {
                    if let idx = project.blobs.firstIndex(where: { $0.id == blob.id }) {
                        project.blobs[idx].sortOrder = i
                    }
                }
            }
        }

        updateProject(project)
    }

    func moveBlobToFolder(_ blobID: UUID, to folderID: UUID, in projectID: UUID) {
        guard let projectIndex = projectIndex(projectID) else { return }

        var project = projects[projectIndex]

        if let index = project.blobs.firstIndex(where: { $0.id == blobID }) {
            let oldFolderID = project.blobs[index].folderID
            project.blobs[index].folderID = folderID
            project.blobs[index].sortOrder = (project.blobs
                .filter { $0.folderID == folderID && $0.id != blobID }
                .min { $0.sortOrder < $1.sortOrder }?
                .sortOrder ?? 0) - 1

            // Rebuild sort orders for both old and new contexts
            if let oldFolderID = oldFolderID {
                rebuildFolderSortOrders(&project, folderID: oldFolderID)
            } else {
                rebuildRootSortOrders(&project)
            }
            rebuildFolderSortOrders(&project, folderID: folderID)
        }

        updateProject(project)
    }

    // MARK: - Blob Content I/O

    func loadBlobContent(blobID: UUID, in projectID: UUID) -> String? {
        let blobFile = rootPath + "/" + projectID.uuidString + "/" + blobID.uuidString + ".json"
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: blobFile)) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func saveBlobContent(_ json: String, blobID: UUID, in projectID: UUID) {
        let blobFile = rootPath + "/" + projectID.uuidString + "/" + blobID.uuidString + ".json"
        guard let data = json.data(using: .utf8) else { return }
        do {
            try data.write(to: URL(fileURLWithPath: blobFile), options: .atomic)
            mutateProject(projectID) { project in
                if let index = project.blobs.firstIndex(where: { $0.id == blobID }) {
                    project.blobs[index].updatedAt = Date()
                }
            }
        } catch {
            print("[ProjectStore] Failed to save blob content: \(error)")
        }
    }

    // MARK: - Private Helpers

    private func save(_ project: Project) {
        let projectPath = rootPath + "/" + project.id.uuidString
        let projectFile = projectPath + "/project.json"

        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(project)
            try data.write(to: URL(fileURLWithPath: projectFile))
        } catch {
            print("Failed to save project: \(error)")
        }
    }

    private func projectIndex(_ id: UUID) -> Int? {
        projects.firstIndex { $0.id == id }
    }

    // Applies `mutator` to the in-memory project at `id` and immediately persists it to disk.
    private func mutateProject(_ id: UUID, mutator: (inout Project) -> Void) {
        guard let index = projectIndex(id) else { return }
        mutator(&projects[index])
        save(projects[index])
        DispatchQueue.main.async {
            self.objectWillChange.send()
        }
    }

    // Replaces the in-memory project copy and persists it. Use `mutateProject` for targeted field changes.
    private func updateProject(_ project: Project) {
        if let index = projectIndex(project.id) {
            DispatchQueue.main.async {
                self.projects[index] = project
                self.save(project)
            }
        }
    }

    private func rebuildRootSortOrders(_ project: inout Project) {
        // Folders and blobs maintain independent sort sequences
        let sortedFolders = project.folders.sorted { $0.sortOrder < $1.sortOrder }
        for (index, folder) in sortedFolders.enumerated() {
            if let i = project.folders.firstIndex(where: { $0.id == folder.id }) {
                project.folders[i].sortOrder = index
            }
        }

        let sortedBlobs = project.blobs
            .filter { $0.folderID == nil }
            .sorted { $0.sortOrder < $1.sortOrder }
        for (index, blob) in sortedBlobs.enumerated() {
            if let i = project.blobs.firstIndex(where: { $0.id == blob.id }) {
                project.blobs[i].sortOrder = index
            }
        }
    }

    private func rebuildFolderSortOrders(_ project: inout Project, folderID: UUID) {
        let blobs = project.blobs
            .filter { $0.folderID == folderID }
            .sorted { $0.sortOrder < $1.sortOrder }

        for (index, blob) in blobs.enumerated() {
            if let blobIndex = project.blobs.firstIndex(where: { $0.id == blob.id }) {
                project.blobs[blobIndex].sortOrder = index
            }
        }
    }
}
