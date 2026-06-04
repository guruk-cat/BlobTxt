# Data Model & Persistence

## Data Structures (`Sources/Models/`)

- **`Project`** — contains `folders` and `blobs`. Serialized to `~/Documents/BlobTxt/<projectID>/project.json`.
- **`BlobFolder`** — id, name, sortOrder. Represents a collection for organizing blobs.
- **`Blob`** — id, optional `folderID`, sortOrder, timestamps, and optional `title`/`author` metadata strings. Content stored separately at `<projectID>/<blobID>.json` as TipTap JSON. `title` and `author` are persisted in `project.json` and default to `nil` for existing blobs.
- **`NavigatorItem`** — enum wrapping `.folder`, `.blob`, or `.ghost`. Used by `FileNavigatorView` for drag-reorder; ghost is the placeholder shown at the drop target during a drag.
- **`ProjectStore.SearchResult`** — nested struct: `blob: Blob`, `matchCount: Int`, `excerpt: BlobExcerpt`. Returned by `searchBlobs`; used by `BlobSearchView` for all-blobs result cards.
- **`ProjectStore.SnippetMatch`** — nested struct: `occurrenceIndex: Int`, `snippet: String`. Returned by `searchSnippets`; used by `BlobSearchView` for single-blob mode result cards.

Data is stored in `~/Documents/BlobTxt/` with one directory per project containing `project.json` (metadata) and individual `<blobID>.json` files for blob content.

## ProjectStore (`Sources/Services/ProjectStore.swift`)

The only persistence layer. Handles all project/folder/blob CRUD operations, including:

- Project lifecycle (create, delete, rename)
- Folder management
- Blob management with move to folder/root
- Sort order rebuilds across folders and root level
- Drag-move logic (`moveItem`, `moveBlobToFolder`, `moveBlobToRoot`)
- TipTap JSON parsing and extraction:
  - `loadBlobExcerpt` — extracts title (first heading, overridden by `blob.title` if set) and body with inline formatting for card previews
  - `loadBlobHeadings` — returns all heading nodes in document order as `[BlobHeading]` (level + plain text); used by `BlobOutlineView`
  - `loadBlobPlainText` — plain text extraction with optional word limit (`maxWords: .max` for full text)
  - `loadBlobWordCount` — word count of blob body text, excluding `footnotes` container nodes
  - `loadBlobHTML` — full HTML generation preserving structure
  - `loadBlobContent` — raw TipTap JSON
  - `exportBlobDocx` — generates a `.docx` archive (OOXML) from TipTap JSON; returns `(data: Data, suggestedName: String)`; see `output.md`
- Blob metadata:
  - `updateBlobMetadata(blobID:in:title:author:)` — writes `title` and `author` into the `Blob` struct via `mutateProject`, persisting them to `project.json`
- Search and replace:
  - `searchBlobs(in:folderID:query:)` — case-insensitive search across all blobs in a project/folder context; returns `[SearchResult]`
  - `searchSnippets(blobID:in:query:snippetRadius:)` — per-occurrence snippet extraction (±60 chars of context by default); returns `[SnippetMatch]`; used by `BlobSearchView` in single-blob mode
  - `replaceAllInBlobs(blobIDs:in:find:replace:)` — case-insensitive in-place text replacement across blob TipTap JSON files; walks all text nodes recursively via `replaceInNode`

`activeEditorBlobID` (`@Published var activeEditorBlobID: UUID? = nil`) tracks whether a blob is currently open in the editor. Set by `EditView.onAppear`, cleared by `EditView.onDisappear`. Read by `BlobTxtApp` to enable/disable **File → Export to Document**. Not persisted.

## AppColors (`Sources/Services/AppColors.swift`)

Loads color palettes from `Resources/colors.json` and exposes SwiftUI `Color` properties. See `colors.md` for the palette design spec.

Computes `isDark` from the `type` field of the active palette (`"dark"` → true, `"light"` → false). Exposes `paletteTypes: [String: String]` and `palettes(ofType:)` for filtering palette lists by type. Produces two JavaScript snippets used by `WebEditorView` for editor theming: `editorCSSVariablesJS()` sets CSS custom properties at document-start (prevents color flash), and `editorCSSInjection()` does a full injection with selection override and requires `document.head`.

`Resources/colors.json` has the structure `{ "paletteName": { "type": "dark"|"light", "color_key": [R, G, B], … } }`. See `colors.md` for the full key reference.

## Follow macOS Appearance

BlobTxt normally manages its color scheme through a manually chosen palette. When "Follow macOS appearance" is enabled, the app tracks the OS light/dark mode and automatically switches between a user-specified dark palette and light palette. A single `Bool` UserDefaults key `"followSystemAppearance"` (default `false`) gates the feature.

| UserDefaults key | Follow-system OFF | Follow-system ON |
| --- | --- | --- |
| `"colorPalette"` | Active palette | Frozen — not read or written |
| `"lastDarkPalette"` | Bookkeeping — last dark palette used | Active — drives the "Dark palette" picker |
| `"lightPalette"` | Not shown | Active — drives the "Light palette" picker |

When follow-system is ON, `preferredColorScheme` is set to `nil` so macOS controls the scheme, making `@Environment(\.colorScheme)` in `ContentView` reflect the real system state and fire `onChange` on a switch.

`AppColors.init()` runs before any SwiftUI view appears, so it cannot use `@Environment`. Instead it reads `UserDefaults(suiteName: "Apple Global Domain")?.string(forKey: "AppleInterfaceStyle")` directly — `"Dark"` is dark mode, anything else (including `nil`) is light — and loads the appropriate palette before the first frame renders, preventing a flash.

At runtime, `ContentView.onChange(of: systemColorScheme)` calls `appColors.applySystemAppearance(dark:)`, which loads the palette from UserDefaults via `loadColors(palette:)`. Toggling follow-system ON fires `SettingsView.autoCorrectPalettesForSystem()` to validate both palette keys before use. Toggling OFF calls `appColors.reloadManualPalette()`, which restores the frozen `"colorPalette"` value.
