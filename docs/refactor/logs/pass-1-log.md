# Pass 1 Log: Data Models and Data Flows

## 1. Overview

This pass replaced the UUID- and JSON-based data architecture with a filesystem-first architecture. Blobs are now `.md` files whose file URL is their identity. Projects are on-disk directories marked by a `.blobtxt` file. The hardcoded `~/Documents/BlobTxt/` root is retired; any directory can be opened as a project.

The navigator's tap-to-open wiring was also completed in this pass. `activeBlobID: UUID?` has been renamed to `activeEditorURL: URL?` to match the new URL-based blob identity. 

## 2. Files Deleted

`BlobTxt/Sources/Models/BlobFolder.swift` — the `BlobFolder` struct. Folders are now real OS subdirectories and require no in-memory model.

`BlobTxt/Sources/Views/ProjectPickerPanel.swift` — the SwiftUI project-picker sheet. Replaced by a native `NSOpenPanel` call wired into `ProjectStore.openProjectWithPanel()`.

Both files were removed from `BlobTxt.xcodeproj/project.pbxproj` (build file entry, file reference entry, group membership, and Sources build phase entry).

## 3. Model Changes

### 3.1. `Blob.swift`

Rewritten. The new struct has two fields: `url: URL` (the file URL, also used as `id`) and `displayName: String` (the filename without the `.md` extension). The old fields (`id: UUID`, `folderID`, `sortOrder`, timestamps, `title`, `author`) are removed. `Blob` conforms to `Identifiable` and `Equatable`.

### 3.2. `Project.swift`

Rewritten. The new struct has two fields: `url: URL` (the directory URL, also used as `id`) and `name: String` (read from the `.blobtxt` marker). The old fields (`id: UUID`, `folders`, `blobs`, `createdAt`) are removed. `Project` conforms to `Identifiable` and `Equatable`.

## 4. ProjectStore Changes

`ProjectStore.swift` was rewritten in full. The file now imports both `SwiftUI` and `AppKit` (the latter for `NSOpenPanel`).

### 4.1. Published State

`@Published var projects: [Project]` is replaced by `@Published var currentProject: Project?`. Only one project is open at a time. The `blobScrollPositions` dict changes its key type from `UUID` to `URL`.

### 4.2. Project Opening

`openProjectWithPanel()` presents an `NSOpenPanel` configured to select folders only. On confirmation it calls `openProject(at:)`.

`openProject(at: URL)` reads the project name from the `.blobtxt` marker (creating it if absent), sets `currentProject`, persists the path to `UserDefaults` under `"lastProjectPath"`, and prepends the path to the recent-projects list under `"recentProjectPaths"` (capped at 10 entries).

`restoreLastProject()` reads `"lastProjectPath"` from `UserDefaults` and calls `openProject(at:)` if the path still points to a valid directory. Called from `init()`.

A `recentProjectURLs` computed property returns the recents list as `[URL]`.

### 4.3. `.blobtxt` Marker

The private `readOrCreateBlobtxt(at:)` helper reads the `name:` key from a YAML-style `.blobtxt` file in the given directory. If the file is absent or the key is missing, the directory name is used as the project name and the marker is created.

### 4.4. Blob Content I/O

`loadBlobContent(url: URL) -> String?` and `saveBlobContent(_ body: String, url: URL)` replace the old UUID-based signatures. Both act as front matter gatekeepers.

On load: if the file starts with `---`, the front matter block (up to and including the closing `---` line) is stripped before the body is returned to the editor.

On save: the existing file is read first to detect any front matter. If found, it is preserved and written before the new body.

Two private helpers support this: `stripFrontMatter(from:)` and `extractFrontMatter(from:)`.

### 4.5. CRUD Operations

All UUID-based project, folder, blob, and sort-order methods are removed. The replacements use `FileManager` directly:

- `createBlob(in: URL) -> Blob?` — creates `untitled.md` in the given directory. Uses `resolveUniqueURL(_:)` to append a numeric suffix (`untitled-2.md`, etc.) if the name is taken.
- `deleteBlob(url: URL)` — removes the file.
- `createFolder(in: URL, name: String)` — creates a subdirectory.
- `deleteFolder(url: URL)` — removes the directory recursively.
- `renameFolder(url: URL, to: String)` — moves the directory to a new name in the same parent.

The old `save(_:)`, `mutateProject(_:)`, `updateProject(_:)`, sort-order management methods, and the JSON-based `loadProjects()` / `ensureRootDirectory()` are all removed.

## 5. View Changes

### 5.1. EditView

`blobID: UUID` and `projectID: UUID` parameters replaced by `url: URL`. All internal references updated: `store.loadBlobContent(url:)`, `store.saveBlobContent(_:url:)`, `store.blobScrollPositions[url]`. The `.reloadEditorContent` notification handler now matches on `URL` instead of `UUID`. An empty-file guard was added so that a newly created empty blob gets the default TipTap JSON document rather than passing an empty string to the editor.

### 5.2. ContentView

`@State var selectedProjectID: UUID?` and `@AppStorage("lastProjectID")` removed. `@State var activeBlobID: UUID?` renamed to `@State var activeEditorURL: URL?`. `@State private var isShowingProjectPicker` and the associated sheet removed.

Project presence is now checked via `store.currentProject != nil`. The "Select Project" button and the `.showProjectPicker` notification handler both call `store.openProjectWithPanel()` directly. A new `.onChange(of: store.currentProject?.url)` clears `activeEditorURL` when the project switches. The `.onAppear` block no longer restores a project (that is handled by `ProjectStore.init()`). All `activeBlobID` guards updated to use `activeEditorURL`.

`SidebarView` is called with `activeEditorURL: $activeEditorURL` instead of `selectedProjectID`.

### 5.3. SidebarView

`@Binding var selectedProjectID: UUID?` replaced by `@Binding var activeEditorURL: URL?`. The binding is passed through to `FileNavigatorView`.

### 5.4. FileNavigatorView

`@Binding var selectedProjectID: UUID?` replaced by `@Binding var activeEditorURL: URL?`. The project is read directly from `store.currentProject` rather than looked up by UUID. The `reload()` function uses `store.currentProject?.url` as the root directory, replacing the hardcoded `~/Documents/BlobTxt/<UUID>` path.

Tap-to-open is wired: tapping a file row sets `activeEditorURL = entry.url`, which `ContentView` observes to show `EditView`. The selected file is highlighted: its icon and label use the accent color, and the row has a faint accent background.

## 6. Things Flagged but Not Changed

`.reloadEditorContent` (defined in `EditorBridge.swift`) — this notification is intended to tell the currently open editor to discard its in-memory content and re-read the file from disk. The receiver in `EditView` was updated as part of this pass: it now expects a `URL` payload and compares it to `url` (the blob's file URL) to decide whether the reload applies to the open document. No code currently posts this notification; its senders (the search and outline panels) were removed in Phase 0. When a future pass reintroduces a feature that needs to trigger an editor reload, it should post `.reloadEditorContent` with a `URL` object as the payload — the receiver in `EditView` is already correct for that.

The blob filename-derivation logic described in section 3.2 of the plan ("on first save, derive a name from the content") is not yet implemented. `createBlob` currently always uses `untitled.md` as the filename. First-save renaming is deferred to the future, to be implemented along with the full navigator rebuild.

Move-blob-between-folders (`moveItem`, `moveBlobToFolder`, `moveBlobToRoot`) had no remaining implementation in the new arch and were removed as part of the full `ProjectStore` rewrite. Their UI triggers don't exist yet, so nothing is regressed.

Project rename (editing `name:` in `.blobtxt`) is not implemented in this pass. The new `Project` model has `var name: String`, so a future pass can add this without a model change.
