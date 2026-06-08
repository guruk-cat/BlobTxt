# Refactor Data Models and Data Flows

In this session, I want to do a lot of the heavy lifting for back-end side of the refactor. We will delete, edit, or create data-related functions and structs that are affected by the architecture change.

## 1. Overview of Current Codebase

The following describes the codebase as it existed before Phase 0. Phase 0 removed a significant portion of what is listed here. This information is provided only as context before reading the current source codes

## 1.1. Data Structures (`Sources/Models/`)

- **`Project`** — contains `folders` and `blobs`. Serialized to `~/Documents/BlobTxt/<projectID>/project.json`.
- **`BlobFolder`** — id, name, sortOrder. Represents a collection for organizing blobs.
- **`Blob`** — id, optional `folderID`, sortOrder, timestamps, and optional `title`/`author` metadata strings. Content stored separately at `<projectID>/<blobID>.json` as TipTap JSON. `title` and `author` are persisted in `project.json` and default to `nil` for existing blobs.
- **`NavigatorItem`** — enum wrapping `.folder`, `.blob`, or `.ghost`. Used by `FileNavigatorView` for drag-reorder; ghost is the placeholder shown at the drop target during a drag.
- **`ProjectStore.SearchResult`** — nested struct: `blob: Blob`, `matchCount: Int`, `excerpt: BlobExcerpt`. Returned by `searchBlobs`; used by `BlobSearchView` for all-blobs result cards.
- **`ProjectStore.SnippetMatch`** — nested struct: `occurrenceIndex: Int`, `snippet: String`. Returned by `searchSnippets`; used by `BlobSearchView` for single-blob mode result cards.

Data is stored in `~/Documents/BlobTxt/` with one directory per project containing `project.json` (metadata) and individual `<blobID>.json` files for blob content. It is important to understand that, in the present app, blobs are stored as loose files at project root. It is through `project.json` that the app determines the order of blobs and the folders they belong. Furthermore, BlobTxt only allows one folder level per project. That is, nested folders are not allowed, and this is reflected in the file navigator UI panel.

## 1.2. ProjectStore (`Sources/Services/ProjectStore.swift`)

The only persistence layer. Handles all project/folder/blob CRUD operations, including:

- Project lifecycle (create, delete, rename)
- Folder management
- Blob management with move to folder/root
- Sort order rebuilds across folders and root level
- Drag-move logic (`moveItem`, `moveBlobToFolder`, `moveBlobToRoot`)
- TipTap JSON parsing and extraction functions.
- Blob metadata:
  - `updateBlobMetadata(blobID:in:title:author:)` — writes `title` and `author` into the `Blob` struct via `mutateProject`, persisting them to `project.json`
- Search and replace:
  - `searchBlobs(in:folderID:query:)`; returns `[SearchResult]`
  - `searchSnippets(blobID:in:query:snippetRadius:)`; returns `[SnippetMatch]`; used by `BlobSearchView` in single-blob mode
  - `replaceAllInBlobs(blobIDs:in:find:replace:)`; walks all text nodes recursively via `replaceInNode`

`activeEditorBlobID` (`@Published var activeEditorBlobID: UUID? = nil`) tracks whether a blob is currently open in the editor. Set by `EditView.onAppear`, cleared by `EditView.onDisappear`. Read by `BlobTxtApp` to enable/disable **File → Export to Document**. 

## 2. Overview of Planned Changes
### 2.1. New Architecture

A **project** is a directory on disk. A `.blobtxt` file marks it as a BlobTxt project and holds minimal project-level config. A **blob** is a `.md` file. Its path is its identity, not a UUID like in the present app architecture. A **folder** is a real OS subdirectory. BlobTxt's navigator reflects the file system; it doesn't own the structure. This eliminates: UUID-based blob identifiers, `project.json` as a structural index, virtual folder management, sort order tracking, and the bulk of ProjectStore's current CRUD logic.

### 2.2. Clarification on Scope

The present pass is focused on providing the groundwork necessary for future passes. The only UI element touched is the project picking service, as described below. The navigator is already replaced with a minimal placeholder in Phase 0 and is not touched here.

## 3. Project and File Structure.
### 3.1. The `.blobtxt` Marker File

When BlobTxt opens a directory for the first time, it creates a `.blobtxt` file. For now this file holds only the project name (which defaults to the directory name). It is not a structural index. It doesn't list blobs or folders. It is purely a marker and a place for future project-level settings. Format will be YAML, consistent with the front matter approach used in blob files:

```yaml
name: My Project
```

If a directory already contains a `.blobtxt` file, BlobTxt reads the name from it. If the file is absent, BlobTxt treats the directory name as the project name and creates the file.

### 3.2. Blob Files

Each blob is a `.md` file anywhere within the project directory tree (including in subdirectories). The file path is the blob's identity. Filename behavior:

- A newly created blob gets the filename `untitled.md`
- On first save, the app derives a name from the content: first heading if present, otherwise the first line of text, slugified to a valid filename. This is the current behavior in the app, with `ProjectStore` having the services necessary for this action.
- If the derived name is already taken in the same directory, a numeric suffix is appended (`extended-mind-2.md`)
- Subsequent frontmatter title changes do not rename the file. The filename is set once on first save and thereafter stable unless the user explicitly renames it in the navigator (or elsewhere, like Finder or Terminal).

### 3.3. Folders

Folders are OS subdirectories. Creating a folder creates a real directory via `FileManager`. Deleting a folder deletes the directory and its contents. Moving a blob between folders moves the file. Nothing about folder structure is stored in `.blobtxt`. All structural information (what blobs exist, what folders exist, what's in what folder) is read directly from the file system.

### 3.4. Persistence Location and Opening a Project

The hardcoded `~/Documents/BlobTxt/` root is retired. Projects can live anywhere the user chooses. Opening a project is done via **File → Open Project**, which presents a native `NSOpenPanel` configured to select a folder. **File → Open Recent** (backed by `NSDocumentController` or a manual `UserDefaults` recent-paths list) provides quick re-access to previously opened project directories. The last open project is restored on launch. 

In the old app, `ProjectPickerPanel.swift` contains the code for the project picking panel open via **File → Open Project**. This panel limits its scope to the `~/Documents/BlobTxt/` root. It is replaced by the above behavior.

## 4. ProjectStore

ProjectStore currently does two things: manages an in-memory model of project structure (blobs, folders, sort orders) and provides content extraction services (plain text, headings, word count, search, export). These two roles now split cleanly.

### 4.1. Structure Management

The in-memory `Project`, `Blob`, `BlobFolder` structs are replaced or dramatically simplified. The new `Blob` model needs only what can't be read directly from the file system:

```swift
struct Blob: Identifiable {
    let url: URL             // File URL is the identity
    var displayName: String  // Derived from filename
}
```

The new `Project` model:

```swift
struct Project: Identifiable {
    let url: URL      // Directory URL
    var name: String  // From .blobtxt (or directory name if project not initated)
}
```

ProjectStore no longer maintains sorted arrays of blobs and folders. Instead, it reads from `FileManager` on demand: listing `.md` files and subdirectories, filtering out hidden files and non-blob files (`.blobtxt`, images, etc.). Support for other file fomats, mostly images, will be considered in the future.

CRUD operations become `FileManager` calls:

- Create blob → `FileManager.createFile` with empty content
- Delete blob → `FileManager.removeItem`
- Rename blob → `FileManager.moveItem` (same directory, new name)
- Move blob → deferred to the full navigator rebuild; no UI trigger exists until then
- Create folder → `FileManager.createDirectory`
- Delete folder → `FileManager.removeItem` (recursive)

### 4.2. Content Extraction Services

Phase 0 deleted the content extraction services that served the retired sidebar panels and output features. The only thing that needs to be added in this context are the following.

Blob files are `.md` files and may include a YAML-style front matter block. `loadBlobContent` and `saveBlobContent` become the front matter gatekeepers. On load: detect and strip the `---` front matter block before passing content to the editor. On save: detect existing front matter in the stored file, preserve it, and write the new content body after it. The editor never sees or touches front matter.

## 5. Active Blob Tracking
### 5.1. Renaming activeBlobID

`ContentView` currently tracks the open blob as `activeBlobID: UUID?`. Phase 1 renames this to `activeEditorURL: URL?` to match the new URL-based blob identity. All downstream views that receive it as a binding or branch on its nil state are updated accordingly. Phase 1 also completes the tap-to-open wiring in the minimal navigator built in Phase 0: tapping a row sets `activeEditorURL` to that blob's file URL, which `ContentView` observes to show `EditView`.

### 5.2. activeEditorBlobID in ProjectStore

`ProjectStore.activeEditorBlobID` is already deleted in Phase 0, alongside the export menu item it gated. No replacement is needed — the active blob is purely view-layer state and does not belong in the store.
