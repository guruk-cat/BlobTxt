# Pass 0 Log: Demolition Pass

## 1. Overview

This document records what was done during the demolition pass described in `scoped-plan-0.md`. The pass cleared out features that will be rebuilt from in future passes. This pass also cleared out the sidebar panels so that future passes don't have back-compatibility obligations. A new, bare-minimum navigator panel shows a flat file list in the project. Nothing more.

## 2. Files Deleted

The following files were removed entirely.

`BlobTxt/Sources/Services/CrossPanelDrag.swift` — the shared drag-reorder state object used by the old `FileNavigatorView`. Deleted as specified.

`BlobTxt/Sources/Models/NavigatorItem.swift` — the `NavigatorItem` enum wrapping folders, blobs, and ghost placeholders for drag-reorder. Deleted as specified.

`BlobTxt/Sources/Views/Sidebar/BlobOutlineView.swift` — the heading outline panel.

`BlobTxt/Sources/Views/Sidebar/BlobSearchView.swift` — the full-text search panel.

`BlobTxt/Sources/Views/Sidebar/BlobMetadataView.swift` — the blob metadata editor panel.

## 3. ProjectStore Reductions

The following were removed from `ProjectStore.swift`:

- `@Published var activeEditorBlobID: UUID?` — gated the now-deleted Export menu item.
- `BlobExcerpt` struct and `loadBlobExcerpt` — TipTap JSON excerpt parser.
- `SearchResult` and `SnippetMatch` structs — used by deleted search functionality.
- `searchBlobs` and `searchSnippets` — full-text search over blob content.
- `replaceAllInBlobs` and the private `replaceInNode` helper — find-and-replace across blobs.
- `BlobHeading` struct and `loadBlobHeadings` — heading outline extractor.
- `loadBlobPlainText` — plain-text extraction with word cap.
- `loadBlobWordCount` — word count calculator.
- `updateBlobMetadata` — title/author metadata writer.
- `loadBlobHTML` and the private `renderNodeHTML` renderer — HTML generation for print/export.
- `exportBlobDocx` and all DOCX-related private methods and the `DocxContext` class — DOCX export pipeline.
- `printBlob` and the private `BlobPrinter` class — print-sheet presenter.
- `extractText`, `buildAttributedBody`, `attributedStringFromNode`, `countOccurrences` — private helpers with no remaining callers.
- `import WebKit` — only needed by the now-deleted `BlobPrinter`.

**Note on `printBlob` and `BlobPrinter`.** The plan's section 2.3 does not list these explicitly. However, both depend on `loadBlobHTML` and `loadBlobExcerpt`, which are listed for deletion. Keeping them would produce a compile error, so they were removed here. The plan's section 2.2 describes print functionality as removed, which aligns with this decision.

## 4. Menu Bar Changes

The `BlobTxtApp.swift` `File` menu group lost the "Export to Document" button and its `.disabled(store.activeEditorBlobID == nil)` guard. The `Notification.Name.exportDocument` extension property was also removed.

Print had no dedicated macOS menu bar entry. The print shortcut was a hidden zero-size `Button` in `EditView` that bound Cmd+P to `store.printBlob`. That button was removed.

## 5. EditView Changes

Three changes were made to `EditView.swift` as cascading consequences of the ProjectStore deletions:

- The hidden Cmd+P print button was removed (`store.printBlob` no longer exists).
- The `.onReceive(.exportDocument)` handler was removed (`store.exportBlobDocx` no longer exists).
- `store.activeEditorBlobID = blobID` in `.onAppear` and `store.activeEditorBlobID = nil` in `.onDisappear` were removed (`activeEditorBlobID` no longer exists).
- `import UniformTypeIdentifiers` was removed; it was only needed by the export handler.

**Note on remaining dead receivers.** `EditView` still receives `.scrollToOutlineHeading`, `.searchAndHighlight`, `.scrollToSearchResult`, and `.clearSearchHighlights`. Their senders (`BlobOutlineView`, `BlobSearchView`) are now deleted, so these receivers are currently unreachable. They are left in place because the editor-side bridge methods they invoke will be needed when those panels are rebuilt in later phases.

## 6. Sidebar Changes

`SidebarView.swift` was rewritten. The `SidebarPanel` enum retains all four cases. When the active panel is `.navigator`, `FileNavigatorView` is shown as before. For `.blobOutline`, `.search`, and `.metadata`, a shared placeholder view is shown that reads "This panel is not yet available."

The `navigatorExpandedFolderIDs` and `navigatorSelectedFolderID` bindings were removed from `SidebarView`'s signature because the new `FileNavigatorView` does not accept them. The `activeBlobID` binding was also removed for the same reason. `ContentView` was updated to match the new signature and the corresponding `@State` properties were removed.

## 7. FloatingIslandView Changes

The three non-navigator buttons (search, outline, metadata) are now rendered with `.disabled(true)` and shown at reduced opacity (`0.35`). They remain visible so the island layout is unchanged.

## 8. New FileNavigatorView

`FileNavigatorView.swift` was replaced with a minimal fresh implementation. Its signature is:

```swift
struct FileNavigatorView: View {
    @Binding var selectedProjectID: UUID?
    ...
}
```

On appear and on project change, it enumerates the project directory (`~/Documents/BlobTxt/<projectID>/`) for `.md` files using `FileManager.enumerator`. Hidden files are skipped by the enumerator options. Results are sorted alphabetically by display name (filename without the `.md` extension). For files not at the project root, the immediate parent directory name appears as secondary text below the filename, making same-named files in different folders distinguishable.

Tap-to-open, drag-and-drop, context menus, and folder expand/collapse are absent. `FSEventStream` watching is not set up; the list refreshes only on appear and when `selectedProjectID` changes.

**Note on hardcoded path.** The navigator computes the project directory as `NSHomeDirectory() + "/Documents/BlobTxt/" + projectID.uuidString`, duplicating the logic in `ProjectStore.init()`. This duplication is a known shortcut for the placeholder phase. Phase 1 is expected to introduce URL-based blob identity that will supersede this.

## 9. Things Flagged but Not Changed

The following items were noticed but are outside this pass's scope. They are recorded here for reference.

`moveItem`, `moveBlobToRoot`, `moveBlobToFolder`, `rebuildSortOrders` in `ProjectStore` — these sort-order management methods operate on the in-memory `Project.blobs` and `Project.folders` arrays, which will likely be retired when blob identity moves to filesystem URLs. They are kept for now since they have no explicit plan entry.

`createFolder`, `deleteFolder`, `renameFolder`, `createBlob`, `deleteBlob` in `ProjectStore` — still reference the old JSON blob file paths (`.json` suffix). These will need to be updated when the storage format migrates to Markdown in a later phase.

`Blob.title`, `Blob.author` fields — set only by the now-deleted `updateBlobMetadata`. They remain on the model struct but are currently unwritable. A later phase will determine if they carry forward.

The `Project.blobs` and `Project.folders` arrays on the `Project` model remain. The new navigator bypasses them entirely by scanning the filesystem. The plan notes that the model will be revisited in Phase 1.
