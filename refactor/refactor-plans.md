# BlobTxt Markdown Migration (Tentative Plans)

## New Architecture

A **project** is a directory on disk. A `.blobtxt` file marks it as a BlobTxt project and holds minimal project-level config. A **blob** is a `.md` file. Its path is its identity, not a UUID like in the present app architecture. A **folder** is a real OS subdirectory. BlobTxt's navigator reflects the file system; it doesn't own the structure. This eliminates: UUID-based blob identifiers, `project.json` as a structural index, virtual folder management, sort order tracking, and the bulk of ProjectStore's current CRUD logic.

## Part 1. Project and File Structure
### 1.1. The `.blobtxt` Marker File

When BlobTxt opens a directory for the first time, it creates a `.blobtxt` file. For now this file holds only the project name (which defaults to the directory name). It is not a structural index. It doesn't list blobs or folders. It is purely a marker and a place for future project-level settings. Format will be YAML, consistent with the front matter approach used in blob files:

```yaml
name: My Project
```

If a directory already contains a `.blobtxt` file, BlobTxt reads the name from it. If the file is absent, BlobTxt treats the directory name as the project name and creates the file.

### 1.2. Blob Files

Each blob is a `.md` file anywhere within the project directory tree (including in subdirectories). The file path is the blob's identity. Filename behavior:

- A newly created blob gets the filename `untitled.md`
- On first save, the app derives a name from the content: first heading if present, otherwise the first line of text, slugified to a valid filename. This is the current behavior in the app, with `ProjectStore` having the services necessary for this action.
- If the derived name is already taken in the same directory, a numeric suffix is appended (`extended-mind-2.md`)
- Subsequent title changes in the metadata panel (which edits the YAML frontmatter at the beginning of the `md` file) do not rename the file. The filename is set once on first save and thereafter stable unless the user explicitly renames it in the navigator (or elsewhere, like Finder or Terminal).

### 1.3. Folders

Folders are OS subdirectories. Creating a folder creates a real directory via `FileManager`. Deleting a folder deletes the directory and its contents. Moving a blob between folders moves the file. Nothing about folder structure is stored in `.blobtxt`. Hence, `project.json` is retired. The `.blobtxt` file replaces it, holding only project-level config. All structural information (what blobs exist, what folders exist, what's in what folder) is read directly from the file system.

## Part 2. ProjectStore

ProjectStore currently does two things: manages an in-memory model of project structure (blobs, folders, sort orders) and provides content extraction services (plain text, headings, word count, search, export). These two roles now split cleanly.

### 2.1. Structure Management

The in-memory `Project`, `Blob`, `BlobFolder` structs are replaced or dramatically simplified. The new `Blob` model needs only what can't be read directly from the file system:

```swift
struct Blob: Identifiable {
    let url: URL             // File URL is the identity
    var displayName: String  // Derived from filename or first heading
}
```

The new `Project` model:

```swift
struct Project: Identifiable {
    let url: URL      // Directory URL
    var name: String  // From .blobtxt or directory name
}
```

ProjectStore no longer maintains sorted arrays of blobs and folders. Instead, it reads from `FileManager` on demand: listing `.md` files and subdirectories, filtering out hidden files and non-blob files (`.blobtxt`, images, etc.). 

CRUD operations become `FileManager` calls:

- Create blob → `FileManager.createFile` with empty content
- Delete blob → `FileManager.removeItem`
- Rename blob → `FileManager.moveItem` (same directory, new name)
- Move blob → `FileManager.moveItem` (new directory)
- Create folder → `FileManager.createDirectory`
- Delete folder → `FileManager.removeItem` (recursive)

### 2.2. Content Extraction Services

These stay in ProjectStore but switch from TipTap JSON parsing to Markdown parsing. Most become simpler:

| Method | Change |
| --- | --- |
| `loadBlobContent` | Reads `.md` file; strips YAML front matter before returning content to editor |
| `saveBlobContent` | Writes `.md` file; re-prepends existing front matter before writing |
| `loadBlobPlainText` | Strip Markdown syntax characters from raw text |
| `loadBlobHeadings` | Regex over lines: `^(#{1,3})\s+(.+)` |
| `loadBlobExcerpt` | First `# ` line as title; first paragraph as body |
| `loadBlobWordCount` | Strip syntax, split on whitespace |
| `loadBlobHTML` | Markdown → HTML via a Swift Markdown parser (see below) |
| `replaceAllInBlobs` | String replacement on raw Markdown (see below) |

**Swift Markdown parser:** `loadBlobHTML` is used by print and DOCX export and needs a proper AST-based conversion, especially for footnotes. One option is to use Apple's `swift-markdown` package (open source, SPM-compatible, CommonMark compliant). A custom visitor handles footnote nodes. This is the only new dependency introduced.

**`replaceAllInBlobs`:** Naive string replacement on the raw Markdown text is acceptable for the initial implementation. The edge case where a search term straddles a formatting boundary (e.g., "hello world" where "hello" is bold and " world" is not) is rare and can be documented as a known limitation. The same limitation existed in the JSON approach for cross-node matches.

### 2.3. Front Matter Handling

`loadBlobContent` and `saveBlobContent` become the front matter gatekeepers. On load: detect and strip the `---` front matter block before passing content to the editor. On save: detect existing front matter in the stored file, preserve it, and write the new content body after it. The editor never sees or touches front matter — that is entirely the metadata panel's domain, addressed in the sidebar refactor.

## Part 3. Editor
### 3.1. Strategy

Keep TipTap and WKWebView. Add a Markdown serialization layer at the `setContent` / `getContent` boundary in `main.js`. Use `@tiptap/extension-markdown` for standard nodes and write custom serializer/deserializer logic for footnote nodes.

### 3.2. What Changes

- `setContent`: accepts a Markdown string, converts to TipTap JSON before loading into editor
- `getContent`: serializes editor JSON to Markdown before returning to Swift

### 3.3. Footnote Serialization

`@tiptap/extension-markdown` does not handle the `footnoteReference` / `footnotes` / `footnote` node types from the buttondown extension. Custom serializer/deserializer logic is needed for these, using Pandoc-style syntax:

```markdown
Here is some text with a note.[^1]

[^1]: The footnote content goes here.
```

- **Markdown → TipTap JSON:** scan for `[^N]` inline markers and `[^N]:` definition blocks;
  reconstruct `footnoteReference` inline nodes and the `footnotes` container node at document end
- **TipTap JSON → Markdown:** walk the `footnotes` container, emit `[^N]:` definitions; replace
  `footnoteReference` nodes with `[^N]` inline markers

These two functions live in `main.js` alongside the existing footnote extensions.

### 3.4. What Does Not Change

- All toolbar commands (`toggleBold`, `setHeading`, etc.)
- Focus mode, wallpaper, fade transitions
- Search highlight extension (`SearchHighlightExtension`)
- User interaction gating extension (`UserInteractionExtension`)
- Footnote clipboard extension (`FootnoteClipboardExtension`) — this solves a TipTap-internal
  clipboard problem, unrelated to storage format
- JS↔Swift bridge message types
- Autosave debounce logic in `EditorBridge.swift` and `EditView.swift`
- The overall pipeline shape: `editorReady` → `setContent` → edit → `getContent` → `saveBlobContent`

## Part 4. Sidebar Panels
### 4.1. File Navigator

The navigator becomes a `FileManager` browser. It reads the directory tree directly. There's no in-memory blob/folder model. It displays:

- Subdirectories (with expand/collapse)
- `.md` files, shown by display name (derived from filename)
- Hidden files, `.blobtxt`, and non-text files filtered from view
- No drag-to-reorder; ordering is OS-native (+ potentially other features in the future)

Image file support and additional viewer types are planned as future work.

Operations:

- New blob → creates `untitled.md` in the current directory or selected folder
- New folder → creates a subdirectory
- Rename → renames file or directory via `FileManager`
- Delete → deletes file or directory, with confirmation

### 4.2. Search

Functionally unchanged from the user's perspective. Internal changes: `loadBlobPlainText` and `replaceAllInBlobs` switch to Markdown parsing. Search now scans all `.md` files in the project directory tree rather than iterating `project.blobs`.

### 4.3. Blob Outline

`loadBlobHeadings` becomes a regex over Markdown lines — simpler than the current JSON walk. The view, collapse/expand logic, and scroll-sync notifications are untouched. Whether to keep or retire this panel is deferred.

### 4.4. Blob Metadata

YAML front matter reading and writing is deferred to the sidebar refactor phase. During this migration, the metadata panel can display read-only information derived from the file system (filename, modification date, word count) without touching front matter yet.

## Part 5. Migration Script

Deferred. When the app-side design is settled, the script (Python) will:

1. Walk the existing project directory
2. For each `<blobID>.json`: convert TipTap JSON → Markdown (including footnotes)
3. Derive a human-readable filename from the blob's title or content
4. Write `<human-readable-name>.md`.
5. Create `.blobtxt` with the project name
6. Delete old `.json` files and `project.json`

## Sequencing

1. **Editor Markdown serialization** — add `@tiptap/extension-markdown` and footnote serializer/deserializer to `main.js`. At this point the editor speaks Markdown but the rest of the app is unchanged. Testable in isolation.

2. **ProjectStore content layer** — switch `loadBlobContent` / `saveBlobContent` to `.md` files with front matter stripping/preservation. Update all extraction methods to parse Markdown. Add `swift-markdown` dependency for HTML generation.

3. **ProjectStore structure layer** — replace the in-memory blob/folder model with `FileManager` reads. Retire `Blob` UUID, `BlobFolder`, and sort order logic. Introduce simplified `Blob` and `Project` structs. Rewrite CRUD as `FileManager` operations.

4. **Navigator refactor** — replace the current view with a `FileManager` browser. New blob / new folder / rename / delete wired to the new ProjectStore operations.

5. **`.blobtxt` handling** — implement project-open logic: scan for `.blobtxt`, create if absent, read project name.

6. **Filename-on-first-save logic** — implement heading/excerpt derivation and `FileManager.moveItem` rename on first save.

7. **Run migration script** — convert existing projects.

8. **DOCX export and print** — update if needed; likely mostly handled by the `loadBlobHTML` change in step 2.
