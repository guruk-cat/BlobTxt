# Plan: BlobTxt Markdown Migration (ProjectStore)

## Context

BlobTxt currently stores blob content as TipTap JSON under a UUID-keyed directory structure at a hardcoded root (`~/Documents/BlobTxt`). This migration transitions the app to Markdown as the canonical format and the filesystem as the source of truth for project structure. This plan covers switching ProjectStore's content layer to Markdown files, and replacing its structure layer with FileManager operations.

## ProjectStore Content Layer

Only `ProjectStore.swift` and the Xcode project file change. No model changes. No view changes.

### Add `swift-markdown` SPM dependency

In Xcode: File → Add Package Dependencies → `https://github.com/apple/swift-markdown`. Add the `Markdown` target to the app target. This is the only new Swift dependency introduced in the migration.

### `ProjectStore.swift` — content method changes

**`loadBlobContent(blobID:in:)`**
Read `<projectUUID>/<blobUUID>.md` instead of `.json`. Strip the YAML front matter block (detect `---\n...\n---\n` at the start of the file) before returning. Return the body Markdown only — the editor never sees front matter.

**`saveBlobContent(_:blobID:in:)`**
Before writing, read the existing `<blobUUID>.md` file (if present) to extract any existing front matter. Prepend that front matter to the new body content and write to `<blobUUID>.md`. If no file exists, write body only. Also updates `blob.updatedAt` via `mutateProject` as before.

**Front matter format** (for reference; reading/writing is deferred to the sidebar refactor):
```
---
title: Optional title
author: Optional author
---
```
The gateway functions `loadBlobContent` / `saveBlobContent` must preserve front matter verbatim — no parsing, no interpretation in this step.

**`loadBlobPlainText(blobID:in:maxWords:)`**
Strip Markdown syntax characters from the raw body text (heading `#` prefixes, `**`, `*`, `_`, `` ` ``, `>`, `[`, `]`, `(`, `)`, `^`-footnote markers, etc.) using regex or character filtering. Split on whitespace, prefix-limit by `maxWords`.

**`loadBlobHeadings(blobID:in:)`**
Replace the JSON walk with a line-by-line regex: `^(#{1,3})\s+(.+)`. Return `[BlobHeading]` with level = capture group 1 count, text = capture group 2 trimmed. Preserve `BlobHeading` struct unchanged.

**`loadBlobExcerpt(blobID:in:)`**
Replace JSON parsing with:
- Title: first line matching `^#\s+(.+)` → capture group 1. Still overridden by `blob.title` metadata if set (that path is unchanged).
- Body: concatenation of the first non-empty, non-heading lines (up to reasonable length).
- `bodyAttributed`: build from the body plain text; bold/italic marks in Markdown previews are deferred — for now return a plain `AttributedString` from the body string. The card previews lose inline mark rendering temporarily; this is acceptable.

**`loadBlobWordCount(blobID:in:)`**
Strip Markdown syntax from body text (same as `loadBlobPlainText`), split on whitespace. Footnote definition blocks (`[^N]: ...` lines) are excluded by skipping lines that match `^\[\^[^\]]+\]:`.

**`loadBlobHTML(blobID:in:)`**
Replace `renderNodeHTML` (the hand-rolled TipTap JSON walker) with a `swift-markdown` AST-based conversion:
- Parse body with `Document(parsing: bodyMarkdown)` (enable GFM-style footnotes if the package option is available; verify during implementation).
- Implement a `MarkupVisitor` struct (`BlobHTMLVisitor`) that walks the AST and emits HTML.
- Footnote references (`[^N]`) → `<sup><a href="#fn:N" ...>[N]</a></sup>`.
- Footnote definitions → `<ol class="footnotes"><li id="fn:N">...content... <a href="#ref:N">↑</a></li></ol>`.
- All other node types follow the same HTML structure as the current `renderNodeHTML` output (so print profiles don't need changes).

**`replaceAllInBlobs(blobIDs:in:find:replace:)`**
Replace the recursive `replaceInNode` JSON walk with string replacement directly on the body text (the content returned by `loadBlobContent`, i.e., front-matter-stripped). Write back via `saveBlobContent` which re-prepends front matter. Known limitation (same as TipTap version): matches straddling Markdown formatting boundaries (e.g., `**hello** world`) are not found. Document this.

### `ProjectStore.swift` — deleted code

Remove entirely:
- `renderNodeHTML(_:)` and all DOCX-related methods: `exportBlobDocx`, `DocxContext`, `docxBlock`, `docxInline`, `docxRPr`, `docxXMLEscape`, `docxFootnoteEntry`, `docxContentTypesXML`, `docxRootRelsXML`, `docxDocumentRelsXML`, `docxDocumentXML`, `docxFootnotesXML`, `docxStylesXML`, `docxNumberingXML`
- `extractText(from:into:)`, `buildAttributedBody(from:)`, `attributedStringFromNode(_:)`, `replaceInNode(_:find:replace:)`

Remove from `EditView.swift`:
- The `.onReceive(NotificationCenter.default.publisher(for: .exportDocument))` block (DOCX export retired).

Remove from `BlobTxtApp.swift`:
- The "Export to Document" `CommandGroup` button and `exportDocument` notification name.

Remove `static let exportDocument` from the `Notification.Name` extension.

---

## ProjectStore Structure Layer

This step replaces the in-memory UUID-keyed model with FileManager operations. Every file that carries `UUID`-based project/blob identity gets updated. The sidebar panel views receive **minimal compatibility updates only** — just enough to compile and remain functional. Their UI/UX refactor is a separate future task.

### Model files

**`Blob.swift`** — replace entirely:
```swift
struct Blob: Identifiable, Equatable {
    let url: URL
    var displayName: String  // derived from filename (stem, humanized)
    var id: URL { url }
}
```

**`Project.swift`** — replace entirely:
```swift
struct Project: Identifiable, Equatable {
    let url: URL
    var name: String         // from .blobtxt or directory name
    var id: URL { url }
}
```

**`BlobFolder.swift`** — delete the file. A "folder" is just a `URL` pointing to a subdirectory.

**`NavigatorItem.swift`** — simplify:
```swift
enum NavigatorItem: Identifiable, Equatable {
    case folder(URL)
    case blob(Blob)
    case ghost
    var id: String { ... } // based on url.path or stable sentinel
}
```

**`CrossPanelDrag.swift`** — update properties from UUID to URL:
- `activeBlobID: UUID?` → `activeBlobURL: URL?`
- `activeProjectID: UUID?` → `activeProjectURL: URL?`
- `targetFolderID: UUID?` → `targetFolderURL: URL?`

### `ProjectStore.swift` — structure layer rewrite

**Published state:**
```swift
@Published var currentProject: Project? = nil
@Published var activeEditorBlobURL: URL? = nil   // replaces activeEditorBlobID: UUID?
var blobScrollPositions: [URL: Int] = [:]         // replaces [UUID: Int]
```

Remove `@Published var projects: [Project]`.

**Project open / `.blobtxt` handling:**
```swift
func openProject(at directoryURL: URL)
```
- Creates `.blobtxt` if absent (writes `name: <directoryName>` YAML).
- Reads `.blobtxt` to populate `currentProject`.
- Saves directory URL to `UserDefaults` recent-projects list (array of path strings, max 10).
- Saves last-opened path to `UserDefaults("lastProjectPath")`.

```swift
func recentProjectURLs() -> [URL]  // reads UserDefaults, filters to existing directories
```

**Directory reads (on-demand, not cached):**
```swift
func contentsOfDirectory(url: URL) -> (blobs: [Blob], folders: [URL])
```
Lists `.md` files (returned as `[Blob]`) and subdirectories (returned as `[URL]`), alphabetically sorted, hidden files and `.blobtxt` filtered out. Called by the navigator and search views instead of reading from an in-memory array.

**CRUD — all become FileManager calls:**
```swift
func createBlob(in directoryURL: URL) -> Blob           // creates untitled.md
func deleteBlob(at url: URL)                            // FileManager.removeItem
func renameBlob(at url: URL, to name: String) -> URL    // FileManager.moveItem, same dir
func moveBlob(at url: URL, to directoryURL: URL) -> URL // FileManager.moveItem, new dir
func createFolder(in parentURL: URL, name: String) -> URL
func deleteFolder(at url: URL)                          // recursive removeItem
func renameFolder(at url: URL, to name: String) -> URL
func renameProject(to name: String)                     // updates .blobtxt
```

Remove entirely: `createProject`, `deleteProject`, `moveBlobToRoot`, `moveBlobToFolder`, `moveItem`, `rebuildRootSortOrders`, `rebuildFolderSortOrders`, `rebuildSortOrders`, `loadProjects`, `ensureRootDirectory`, `save(_:)`, `updateProject(_:)`, `mutateProject(_:mutator:)`, `projectIndex(_:)`.

**Content methods** — update signatures to URL-based (replacing `blobID: UUID, in projectID: UUID`):
```swift
func loadBlobContent(at url: URL) -> String?
func saveBlobContent(_ markdown: String, at url: URL)
func loadBlobExcerpt(at url: URL) -> BlobExcerpt
func loadBlobPlainText(at url: URL, maxWords: Int) -> String?
func loadBlobHeadings(at url: URL) -> [BlobHeading]
func loadBlobWordCount(at url: URL) -> Int
func loadBlobHTML(at url: URL) -> String?
func searchBlobs(in directoryURL: URL, query: String) -> [SearchResult]
func searchSnippets(at url: URL, query: String, snippetRadius: Int) -> [SnippetMatch]
func replaceAllInBlobs(at urls: [URL], find: String, replace: String)
func printBlob(at url: URL)
```

`SearchResult` — update `blob: Blob` to use the new `Blob` struct (no other structural change).

**`loadBlobExcerpt` metadata title override:** The `blob.title` override (previously read from the in-memory `Blob` struct) is removed for now. Front matter title reading is deferred to the sidebar refactor. The override path is deleted; the content-derived title is always used.

### `BlobTxtApp.swift`

- Remove the "Export to Document" button and `exportDocument` notification (already covered in Step 2).
- `store.activeEditorBlobID` → `store.activeEditorBlobURL` in the `.disabled(...)` modifier.

### `ContentView.swift`

Replace UUID-based state with URL-based:
- `@State var selectedProjectID: UUID?` → `@State var selectedProjectURL: URL?`
- `@State var activeBlobID: UUID?` → `@State var activeBlobURL: URL?`
- `@AppStorage("lastProjectID")` → `@AppStorage("lastProjectPath")`
- `navigatorExpandedFolderIDs: Set<UUID>` → `Set<URL>`
- `navigatorSelectedFolderID: UUID?` → `URL?`

On `.showProjectPicker`: present `NSOpenPanel` configured to select a directory (not `ProjectPickerPanel`). On confirmation, call `store.openProject(at: url)` and set `selectedProjectURL`.

On `.onAppear`: restore last project from `UserDefaults("lastProjectPath")` by calling `store.openProject(at: lastURL)` if the path exists.

Pass `selectedProjectURL` and `activeBlobURL` down to `SidebarView` and `EditView`.

### `ProjectPickerPanel.swift`

The current modal panel (create/rename/delete projects from the UUID-based `store.projects` list) is replaced by a **recent projects panel** that lists `store.recentProjectURLs()` and a "Open Other…" button that presents `NSOpenPanel`. Keep the same SwiftUI sheet presentation pattern. Create/rename/delete project operations are retired from this panel (project lifecycle is now managed via Finder or `NSOpenPanel`).

### `EditView.swift`

Replace `let blobID: UUID` and `let projectID: UUID` with `let blobURL: URL`:
- All `store.load*(blobID:in:)` and `store.saveBlobContent(_:blobID:in:)` calls → URL-based variants.
- `store.blobScrollPositions[blobID]` → `store.blobScrollPositions[blobURL]`.
- `store.activeEditorBlobID = blobID` / `= nil` → `store.activeEditorBlobURL`.
- Print shortcut: `store.printBlob(blobID:in:)` → `store.printBlob(at: blobURL)`.
- The content fallback (empty doc) stays the same.

Update `ContentView` to pass `blobURL` instead of `blobID` + `projectID` when constructing `EditView`.

### `SidebarView.swift`

Update all `@Binding` types from UUID to URL. Pass `selectedProjectURL`, `activeBlobURL`, `navigatorExpandedFolderIDs: Set<URL>`, `navigatorSelectedFolderID: URL?` to panel views.

### Sidebar panel compatibility shims (minimal — full refactor deferred)

**`FileNavigatorView.swift`:** Rewrite as a minimal FileManager browser. Drop all drag-reorder-between-blobs logic (all three `*Drag` gesture handlers, `ItemFrameKey`, ghost index helpers, `displayFolders`/`displayRootBlobs`/`displayFolderBlobs`). Replace with a straightforward recursive directory reader calling `store.contentsOfDirectory(url:)`. Show folders (expandable) and `.md` blobs. Retain drag-blob-into-folder using `store.moveBlob(at:to:)`. Retain context menus for rename/delete. `BlobTreeRow` and `BlobDragPreview` update to call `store.loadBlobExcerpt(at:)`.

**`BlobSearchView.swift`:** Update bindings and method calls to URL-based signatures. `searchBlobs(in:folderID:query:)` → `searchBlobs(in: directoryURL, query:)`. `replaceAllInBlobs(blobIDs:in:find:replace:)` → `replaceAllInBlobs(at: urls, find:replace:)`. The `selectedFolderID` binding simplifies to `URL?`.

**`BlobMetadataView.swift`:** Remove `blob.title`/`blob.author` fields (not in new `Blob` struct). Display filename (from `blob.url.deletingPathExtension().lastPathComponent`) as read-only title. Keep word count (`store.loadBlobWordCount(at:)`) and modification date (via `FileManager.default.attributesOfItem(atPath:)[.modificationDate]`). Remove the editable title/author fields and `store.updateBlobMetadata` call. Mark this as a placeholder until the sidebar refactor adds YAML front matter editing.

**`BlobOutlineView.swift`:** Update `store.loadBlobHeadings(blobID:in:)` → `store.loadBlobHeadings(at:)`. Everything else (collapse/expand, scroll sync) is unchanged.

---

## Verification

### 1/2
1. Run the migration script (`refactor/migrate_blobs.py`) on a test project to convert existing `.json` blobs to `.md`.
2. Launch app, open the migrated project.
3. Open a blob — verify editor loads the Markdown content correctly.
4. Edit and save — verify the `.md` file on disk contains the updated Markdown with front matter preserved.
5. Test print: File → Print. Verify HTML output (headings, lists, footnotes) renders correctly in the print sheet.
6. Test search: verify cross-blob search returns results, snippet cards show correct context, replace-all modifies the `.md` files correctly.
7. Test word count, headings outline.

### 2/2
1. Launch app. Verify "Select Project" opens an `NSOpenPanel` (folder picker).
2. Open a directory containing `.md` files. Verify navigator shows the file tree.
3. Create, rename, delete a blob and a folder via context menus. Verify FileManager operations take effect on disk.
4. Open a blob, edit, save. Verify file is updated.
5. Quit and relaunch. Verify the last-opened project is restored.
6. Verify search and metadata panel still function with the new URL-based signatures.
