# Pass 3 Log: Dead Code Removal

## 1. Overview

This pass removed code made dead by Pass 0 (demolition) and Pass 1 (data model rewrite). No features were changed. The editor rebuild planned for this pass has not started; all changes here are strictly removals of unreachable code.

## 2. EditView.swift

Five `onReceive` handlers were removed. Their senders (`BlobOutlineView`, `BlobSearchView`) were deleted in Pass 0. The handlers were explicitly flagged as unreachable stubs in the Pass 0 log and left for later cleanup.

- `.scrollToOutlineHeading` — called `bridge.scrollToHeading(index:)`
- `.searchAndHighlight` — called `bridge.searchAndHighlight(query:)`
- `.scrollToSearchResult` — called `bridge.scrollToSearchResult(index:)`
- `.clearSearchHighlights` — called `bridge.clearSearchHighlights()`
- `.reloadEditorContent` — reloaded file content from disk. The Pass 1 log noted the receiver was kept for future use, but no sender was ever introduced; it is removed here along with the other stubs.

## 3. EditorBridge.swift

### 3.1. Message Handler

The `"headingVisible"` case was removed from the `userContentController` switch. The JS that posted this message (`detectActiveHeading` in `toolbarInitJS`) is also removed (see section 5). Even before that removal, the case was effectively dead: it re-posted `.activeHeadingChanged`, which had no receiver since `BlobOutlineView` was deleted in Pass 0.

### 3.2. Methods

Four methods were removed. Each was only called from an `EditView` `onReceive` handler deleted in section 2.

- `scrollToHeading(index:)`
- `searchAndHighlight(query:)`
- `scrollToSearchResult(index:)`
- `clearSearchHighlights()`

### 3.3. Notification Names

Six `Notification.Name` extension properties were removed. None had both a live sender and a live receiver after Pass 0.

- `scrollToOutlineHeading` — was posted by `BlobOutlineView` (deleted Pass 0)
- `activeHeadingChanged` — was received by `BlobOutlineView` (deleted Pass 0)
- `searchAndHighlight` — was posted by `BlobSearchView` (deleted Pass 0)
- `scrollToSearchResult` — was posted by `BlobSearchView` (deleted Pass 0)
- `clearSearchHighlights` — was posted by `BlobSearchView` (deleted Pass 0)
- `reloadEditorContent` — had a receiver in `EditView` but no sender anywhere in the codebase

`toggleFocusMode` and `focusCustomizationChanged` are retained; both have active senders and receivers.

## 4. WebEditorView.swift

The heading outline block inside `toolbarInitJS` was removed. This block contained:

- `detectActiveHeading()` — scanned `h1–h6` elements and posted `headingVisible` to Swift
- `window.scrollToHeading(index)` — scrolled to a heading by DOM index; exposed as a global for `bridge.scrollToHeading(index:)`, which is now also removed
- A throttled `scroll` event listener on `#editor` that called `detectActiveHeading()`

The rest of `toolbarInitJS` (formatting commands, dropdowns, copy/close chrome) is unchanged. It is slated for full removal when the editor rebuild (Pass 3 proper) runs.

## 5. SettingsView.swift

The "Printing" settings section was removed. Print functionality (`printBlob`, `BlobPrinter`, `loadBlobHTML`) was deleted in Pass 0 with no replacement. The settings UI for it was left in place at that time and is removed here.

Removed:

- `@AppStorage("printProfile")` stored property
- `@State private var availablePrintProfiles` state property
- The "Print profile" `settingsSection` block with its `Picker` and `ForEach`
- `loadPrintProfiles()` call inside `.task`
- `loadPrintProfiles()` function, which looked for `.css` files in a `print-profiles` bundle subdirectory

## 6. AppColors.swift

Two color tokens were removed. Neither was referenced in any view file after the Pass 0 deletions.

- `chromeSidebar` — loaded from `chrome_sidebar` in the palette; no remaining UI consumer
- `destructive` — loaded from `destructive` in the palette; no remaining UI consumer

Both properties and their corresponding `loadColors` assignments were removed. The underlying keys still exist in `colors.json`; removing them from there is outside this pass's scope.

## 7. Things Not Changed

The following are left for the editor rebuild pass:

- `toolbarInitJS` in `WebEditorView.swift` (the remaining portions)
- `EditorState` struct and all associated published state in `EditorBridge`
- Toolbar formatting methods (`toggleBold`, `toggleItalic`, etc.)
- Link dialog machinery (`showLinkDialog`, `pendingLinkHref`, `LinkDialogView.swift`)
- Image insertion machinery (`openImagePicker`, `insertImage`, `pendingImageInsert`)
- `writeToClipboard`, `refocusWebView`, `URL.mimeType`
- The `"stateUpdate"`, `"copyAll"`, `"closeEditor"`, `"insertLink"`, `"insertImage"` message handler cases

These are all live in the current (Milkdown) editor and will be removed as part of the CodeMirror rebuild.
