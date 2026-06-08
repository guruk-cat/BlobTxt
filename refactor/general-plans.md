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

### 1.4. Persistence Location

The hardcoded `~/Documents/BlobTxt` root is retired. Projects can live anywhere the user chooses. Opening a project is done via **File → Open Project**, which presents a native `NSOpenPanel` configured to select a folder. **File → Open Recent** (backed by `NSDocumentController` or a manual `UserDefaults` recent-paths list) provides quick re-access to previously opened project directories. The last open project is restored on launch.

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

ProjectStore no longer maintains sorted arrays of blobs and folders. Instead, it reads from `FileManager` on demand: listing `.md` files and subdirectories, filtering out hidden files and non-blob files (`.blobtxt`, images, etc.). Support for other file fomats, mostly images, will be considered in the future.

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

**Swift Markdown parser:** `loadBlobHTML` is used by print and needs a proper AST-based conversion, especially for footnotes. Apple's `swift-markdown` package (open source, SPM-compatible, CommonMark compliant) handles this. A custom visitor handles footnote nodes. This is the only new Swift dependency introduced.

**`replaceAllInBlobs`:** Naive string replacement on the raw Markdown text is acceptable for the initial implementation. The edge case where a search term straddles a formatting boundary (e.g., "hello world" where "hello" is bold and " world" is not) is rare and can be documented as a known limitation. The same limitation existed in the JSON approach for cross-node matches.

### 2.3. Front Matter Handling

`loadBlobContent` and `saveBlobContent` become the front matter gatekeepers. On load: detect and strip the `---` front matter block before passing content to the editor. On save: detect existing front matter in the stored file, preserve it, and write the new content body after it. The editor never sees or touches front matter — that is entirely the metadata panel's domain, addressed in the sidebar refactor.

## Part 3. Editor
### 3.1. Strategy

Replace TipTap with **Milkdown**. Milkdown is a WYSIWYG rich text editor built on ProseMirror, designed from the ground up with Markdown as the canonical format. It uses remark under the hood for parsing and serializing, which gives us well-tested footnote support (via remark-gfm, which includes GitHub-style footnotes) and reliable round-trip fidelity for all standard nodes.

WKWebView and the Swift bridge pattern are unchanged. `window.editorBridge` remains the API surface between JS and Swift. The overall pipeline shape is the same: `editorReady` → `setContent` → edit → `getContent` → `saveBlobContent`.

Underline formatting is retired. There is no standard Markdown syntax for underline, and it is not worth encoding as HTML in `.md` files. It is dropped from the toolbar and from the data model.

### 3.2. What Is Retired

- TipTap and all `@tiptap/*` packages
- `tiptap-footnotes` (replaced by Milkdown/remark footnote handling)
- `FootnoteClipboardExtension` paste-side workaround (remark handles pasted footnote Markdown correctly without schema-fitting problems)
- `UserInteractionExtension` as a TipTap extension (replaced by a Milkdown plugin; see 3.4)
- `SearchHighlightExtension` as a TipTap extension (replaced by a Milkdown plugin; see 3.4)
- Underline formatting (toolbar button, mark, and any underline-related CSS)
- `TaskList` and `TaskItem` extensions (unused in practice)
- DOCX export (out of scope for this refactor)

### 3.3. Markdown Format

`setContent` accepts a Markdown string; `getContent` returns a Markdown string. The conversion between Markdown and Milkdown's internal ProseMirror representation happens entirely inside JS. Swift reads/writes `.md` files and passes raw Markdown strings across the bridge — it never sees or interprets the internal document format.

Footnotes use sequential integer IDs in the file:

```markdown
Here is some text with a note.[^1]

[^1]: The footnote content goes here.
```

This is clean, portable Markdown compatible with CommonMark/GFM footnote syntax. No UUID-based footnote identity is needed. The integer ID is stable within a file edit session; it is re-derived from position on every save.

### 3.4. Features Rebuilt as Milkdown Plugins

**Custom cursor.** The div-based cursor replacement is reimplemented as a Milkdown plugin. The coordinate logic (`coordsAtPos`, `getBoundingClientRect`) is unchanged. Registration changes from a TipTap extension to a Milkdown plugin slot.

**Keystroke gating.** The behavior of blocking keystrokes until the user has clicked to establish a cursor position is preserved. It is reimplemented as a Milkdown ProseMirror plugin. The toolbar no longer needs this flag for state gating — Milkdown exposes editor state directly.

**Search highlight.** ProseMirror decoration plugin using the same algorithm: find text ranges, apply `Decoration.inline` with the `search-highlight` CSS class. Registered via Milkdown's plugin system. The Swift side (`bridge.searchAndHighlight`, `bridge.scrollToSearchResult`, `bridge.clearSearchHighlights`) is unchanged.

**Centered autoscroll.** The `doCenteredScroll` function is unchanged. It is registered via Milkdown's `onUpdate` listener rather than TipTap's `onUpdate` callback.

**Footnote tooltip and click-to-scroll.** DOM event listeners on the editor container. Logic unchanged; registration unchanged.

**Footnote clipboard — copy side.** When copying a selection that contains `[^N]` inline markers, the referenced `[^N]: definition` blocks are outside the selection (they live at doc end). A custom copy handler intercepts the copy event, scans the selection for markers, and appends the matching definitions to the clipboard Markdown. This is simpler than the TipTap version — string operations on Markdown rather than HTML DOM manipulation and ProseMirror serialization.

### 3.5. Features Unchanged

**Scroll position persistence.** The debounced scroll event listener posting `scrollPositionChanged` to Swift is pure DOM code, independent of the editor framework. Unchanged.

**Focus mode.** `setFocusMode` toggles a CSS class on `document.body`. Unchanged. The wallpaper, dimness, blur, and floating panel customizations are out of scope for this refactor; placeholder implementations are sufficient.

**JS↔Swift message types.** All message names and payloads in both directions are preserved.

**Autosave debounce logic.** `EditorBridge.swift` and `EditView.swift` are unchanged except as noted below.

### 3.6. Swift Bridge Changes

`setContent` in `main.js` calls Milkdown's `replaceAll(markdown)` action instead of `editor.commands.setContent`. `getContent` returns `editor.action(getMarkdown())` (Milkdown's serializer action).

`EditorBridge.swift` — two changes only:

- `getContent(completion:)` evaluates `window.editorBridge.getContent()` (a thin wrapper added to `window.editorBridge`) instead of `JSON.stringify(window.editor.getJSON())`.
- `setContent(_:)` and its scroll variants must pass the Markdown string as a JS string literal rather than as a raw JSON value. The current pattern (`var c = \(jsonString)`) works for JSON objects but not for Markdown strings. Use `JSONSerialization` to produce a properly escaped JS string literal from the Swift `String`.

## Part 4. Sidebar Panels

Sidebar panels will, in certain aspects, go through a major refactor. Hence, the present refactor will focus on basic changes to support new data models, and defer detailed refactors of the actual panel UI/UX to future work.

### 4.1. File Navigator

The navigator becomes a `FileManager` browser. It reads the directory tree directly. There's no in-memory blob/folder model. It displays:

- Subdirectories (with expand/collapse)
- `.md` files, shown by display name (derived from filename)
- Hidden files, `.blobtxt`, and non-text files filtered from view
- Ordering is alphabetical by filename (OS-native)

Drag-to-reorder between blobs is retired. Drag-a-blob-into-a-folder remains, implemented as a `FileManager.moveItem` call. The drag helper (`CrossPanelDrag.swift`) is rewritten to work with file URLs rather than blob UUIDs and folder UUIDs. Moreover, the current navigator only supports 1 folder levels within a project. This limitation will also be gone.

Operations:

- New blob → creates `untitled.md` in the current directory or selected folder
- New folder → creates a subdirectory
- Rename → renames file or directory via `FileManager`
- Delete → deletes file or directory, with confirmation

### 4.2. File Watching

Because project structure is now the live file system, changes made outside BlobTxt (Finder, Terminal, other apps) need to be reflected in the navigator. An `FSEventStream` watcher is registered on the project directory when a project is open and torn down when it closes. On a file system event, the navigator re-reads the directory tree and updates its displayed list. Debouncing (e.g., 500ms after the last event) prevents excessive refreshes during bulk operations.

This does not cover the case of an external edit to an already-open blob. That edge case (external edit while the blob is open in the editor) is a known limitation for this refactor.

### 4.3. Search

Functionally unchanged from the user's perspective. Internal changes: `loadBlobPlainText` and `replaceAllInBlobs` switch to Markdown parsing. Search now scans all `.md` files in the project directory tree rather than iterating `project.blobs`.

### 4.4. Blob Outline

`loadBlobHeadings` becomes a regex over Markdown lines — simpler than the current JSON walk. The view, collapse/expand logic, and scroll-sync notifications are untouched. Whether to keep or retire this panel is deferred. For now, a blank placeholder panel will do.

### 4.5. Blob Metadata

YAML front matter reading and writing is deferred to the sidebar refactor phase. During this migration, the metadata panel can display read-only information derived from the file system (filename, modification date, word count) without touching front matter yet.

## Part 5. Migration Script

For existing BlobTxt projects, `migrate_blobs.py` does the following:

1. Walk the existing project directory
2. For each `<blobID>.json`: convert TipTap JSON → Markdown (including footnotes, using sequential integer IDs)
3. Derive a human-readable filename from the blob's title or content
4. Write `<human-readable-name>.md` into appropriate subdirectories based on `project.json`

Additionally, the following have to be done once app refactor is complete:

5. Create `.blobtxt` with the project name
6. Delete old `.json` files and `project.json`

## Sequencing

1. **Editor rebuild (Milkdown)** — replace TipTap with Milkdown in `editor-src/`. Rebuild toolbar wiring, custom cursor, keystroke gating, centered autoscroll, search highlight, and footnote clipboard as Milkdown plugins. At this point the editor speaks Markdown at the `setContent`/`getContent` boundary but the rest of the app is unchanged. Testable in isolation.

2. **ProjectStore content layer** — switch `loadBlobContent` / `saveBlobContent` to `.md` files with front matter stripping/preservation. Update all extraction methods to parse Markdown. Add `swift-markdown` dependency for print HTML generation.

3. **ProjectStore structure layer** — replace the in-memory blob/folder model with `FileManager` reads. Retire `Blob` UUID, `BlobFolder`, and sort order logic. Introduce simplified `Blob` and `Project` structs. Rewrite CRUD as `FileManager` operations.

4. **Navigator refactor** — replace the current view with a `FileManager` browser. New blob / new folder / rename / delete wired to the new ProjectStore operations. Rewrite drag helper for file-URL-based drag-into-folder.

5. **`.blobtxt` handling and project open UX** — implement project-open logic: `File → Open Project` via `NSOpenPanel`, recent projects list, launch-time restore. Scan for `.blobtxt` on open, create if absent, read project name.

6. **File watching** — register `FSEventStream` on project open; wire events to navigator refresh.

7. **Filename-on-first-save logic** — implement heading/excerpt derivation and `FileManager.moveItem` rename on first save.

8. **Run migration script** — convert existing projects.
