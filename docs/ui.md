# UI

## Editor

### UX Overview

The editor occupies the right side of the app window whenever a blob is open. It is a rich text editor built on TipTap (ProseMirror), hosted inside a WKWebView. The toolbar provides: bold, italic, underline, blockquote, heading levels (H1–H3), bullet and ordered lists, hyperlinks, and image insertion.

The editor autosaves 5 seconds after a change, and also saves on ⌘S, on ESC, and when the app quits. A small "Saving..." / "Saved!" island confirms save state.

Focus mode (⌘M or View → Focus Mode) hides the sidebar, constrains the toolbar and editor to a centered 820px column, and flanks it with black gutters. ESC exits focus mode when active rather than closing the editor. When both focus mode and fullscreen are on, the fullscreen customizations from Settings → Customize focus mode activate: a floating editor panel with rounded corners, a wallpaper image behind the gutters, and adjustable dimness and blur.

### Entry and Shell

`Sources/App/BlobTxtApp.swift` is the `@main` entry point. It installs `ProjectStore` and `AppColors` as environment objects, wires a ⌘S `saveDocument` notification, flushes a save on app quit via `AppDelegate` (with a 600ms sleep to give the async save time to complete), and registers View → Focus Mode (⌘M) via `CommandGroup` which posts `.toggleFocusMode`. Also registers font size shortcuts (⌘+/⌘-) and sidebar toggles (⌘E/⌘F/⌘O). `AppDelegate.applicationDidFinishLaunching` installs an `NSEvent` monitor to intercept ⌘E at the app level — necessary because `NSTextView.useSelectionForFind:` consumes it before the SwiftUI menu shortcut fires when a text or web view holds focus.

`Sources/Views/ContentView.swift` is the root layout. `SidebarView` sits on the left (hidden when `isFocusMode` is true). On the right, either a "Open a document" placeholder (no blob active) or `EditView` (when `activeBlobID != nil`) renders inside a `ZStack` over the surface background. `ContentView` owns `isFocusMode` and `isFullScreen`; it listens for `.toggleFocusMode`, tracks fullscreen via `NSWindow` notifications, and resets focus mode when the editor closes. On `isFocusMode` or `isSidebarOpen` change, it drops `editorOpacity` to 0 then fades it back in over 300ms to hide the layout shift.

### EditView (`Sources/Views/Editor/EditView.swift`)

Hosts the WebKit editor and manages the save lifecycle:

- Listens for `.saveDocument` (⌘S or app quit)
- Autosaves 5 seconds after the first dirty event
- Saves before closing/hiding
- Shows "Saving..." / "Saved!" island
- Reapplies colors on palette change via `bridge.applyColors()`
- ESC: exits focus mode if active and "Enable in full screen by default" is OFF, otherwise saves and closes
- ⌘M: toggles focus mode

On `isReady`, checks `store.blobScrollPositions[blobID]`; if a saved pixel offset exists, calls `bridge.setContentAndScrollTo(_:scrollTop:)` instead of `bridge.setContentAndScrollToTop(_:)` to restore scroll position. On `onDisappear`, writes `bridge.lastScrollPosition` back to `store.blobScrollPositions[blobID]`.

Receives `@Binding var isFocusMode` and `let isFullScreen` from `ContentView`. Fullscreen customizations only apply when `isFocusMode && isFullScreen`. Listens for `.focusCustomizationChanged` (posted by `FocusCustomizationView`) and re-applies customizations if currently in active custom mode. Presents `LinkDialogView` as a sheet when `bridge.showLinkDialog` is true.

### WebEditorView (`Sources/Views/Editor/WebEditorView.swift`)

`NSViewRepresentable` wrapping `WKWebView` that loads `Resources/editor.html`.

Injection timing:
- Document-start: color CSS variables (prevents flash)
- Document-end: toolbar wiring JavaScript (`toolbarInitJS`) — wired after TipTap modules load

`toolbarInitJS` wires click handlers for all toolbar controls and a ⌘K keydown listener on the editor DOM that posts `insertLink` to Swift. Uses `WeakMessageHandler` to prevent a retain cycle between `WKUserContentController` and `EditorBridge`.

Registers `WallpaperSchemeHandler` on the `WKWebViewConfiguration` for the `blobtxt://` custom URL scheme. When WebKit requests `blobtxt://wallpaper?t=<timestamp>`, the handler reads the file at `focusWallpaperPath` from UserDefaults on a background thread and streams the bytes back. The timestamp busts WebKit's cache when the wallpaper is replaced. Updates auto-scroll mode, font, and image half-width on settings changes via the coordinator.

### EditorBridge (`Sources/Views/Editor/EditorBridge.swift`)

`ObservableObject` + `WKScriptMessageHandler` bridging JavaScript ↔ Swift.

Published state: `isReady`, `isDirty`, `editorState` (current formatting state), `showLinkDialog`, `pendingLinkHref`. Non-published: `lastScrollPosition` (most recent `scrollTop` from the JS scroll listener; not `@Published` to avoid unnecessary redraws).

JS → Swift messages:

| Message | Behavior |
| --- | --- |
| `editorReady` | Marks editor initialized |
| `documentChanged` | Marks dirty |
| `stateUpdate` | Updates `editorState` |
| `copyAll` | Copies HTML + plain text to clipboard |
| `closeEditor` | Triggers save and close |
| `insertLink` | Sets `pendingLinkHref` and `showLinkDialog = true`; payload includes `href` of existing link or null |
| `openURL` | Opens URL via `NSWorkspace.shared.open` |
| `insertImage` | Opens `NSOpenPanel`, base64-encodes the file, calls back via `insertImage(src:)` |
| `headingVisible` | Re-posts as `activeHeadingChanged` notification for `BlobOutlineView` |
| `scrollPositionChanged` | Updates `lastScrollPosition`; debouncing is done in JS (300ms after scroll stops) |

Swift → JS commands: formatting toggles (`toggleBold`, `toggleItalic`, `toggleUnderline`, `toggleBlockquote`, `toggleBulletList`, `toggleOrderedList`), `setHeading(level:)`, `addFootnoteReference()`, content (`setContent`, `getContent`, `setContentAndScrollTo(_:scrollTop:)`), navigation (`scrollToTop`, `scrollToHeading(index:)`), search (`searchAndHighlight(query:)`, `scrollToSearchResult(index:)`, `clearSearchHighlights()`), theming (`applyColors`, `setAutoScroll`, `setFocusMode`, `applyFocusModeCustomizations`, `setFontSize(_:)`, `setFontFamily(_:)`), wallpaper (`setFocusWallpaper(dataURL:)`), image (`insertImage(src:)`, `setImageHalfWidth`), link (`setLink(url:)`, `unsetLink()`).

`evaluateJavaScript` (via `evaluate(_:)`) is used for style injection and works after `webView(_:didFinish:)` with a short delay. `callAsyncJavaScript` is used for image insertion because it handles larger payloads safely. Do not treat these as interchangeable.

`writeToClipboard(html:plainText:)` wraps HTML in a UTF-8 document wrapper so Pages/Word handle multi-byte characters correctly.

Notification names defined in `EditorBridge.swift`:

- `scrollToOutlineHeading` — posted by `BlobOutlineView` (object: heading index); received by `EditView` to scroll the editor
- `activeHeadingChanged` — posted by `EditorBridge` on `headingVisible`; received by `BlobOutlineView` to highlight the active row
- `toggleFocusMode` — posted by `BlobTxtApp`; received by `ContentView`
- `focusCustomizationChanged` — posted by `FocusCustomizationView`; received by `EditView`
- `searchAndHighlight`, `scrollToSearchResult`, `clearSearchHighlights`, `reloadEditorContent` — posted by `BlobSearchView`; received by `EditView`

### Editor Source (`editor-src/`)

`Resources/editor.html` is generated by a Vite build — do not edit it directly. Source files:

- `editor.html` — HTML entry point: `#focus-bg` div (wallpaper/dimness layer), toolbar markup, `#editor` div, `#footnote-tooltip` div.
- `src/main.js` — all editor logic: TipTap initialization, Swift bridge (`window.editorBridge`), custom cursor, centered-scroll mode, footnote tooltip and click handling, hyperlink ⌘+click and ⌘K. A debounced scroll listener posts `{ type: 'scrollPositionChanged', scrollTop }` to Swift 300ms after the user stops scrolling.
- `src/style.css` — all editor CSS: toolbar, ProseMirror content styles, footnotes, custom cursor, focus mode. `sup { line-height: 0 }` prevents footnote superscripts from expanding line height. Focus mode styles live at the bottom of this file.
- `vite.config.js` — uses `vite-plugin-singlefile` to inline everything into a single `editor.html`. Output goes to `../BlobTxt/Resources/`.

To rebuild after editing source files:

```bash
cd editor-src
npm run build
```

TipTap's Document schema is extended to `block+ footnotes?` so `tiptap-footnotes` can place a `footnotes` node at the end. `window.editorBridge` is the JS object Swift calls via `evaluateJavaScript`. `window.webkit.messageHandlers.editorBridge` is the handler JS posts messages to.

The custom cursor (`#custom-cursor`) replaces the native caret. It is repositioned in `updateCursor()` on every selection/focus/update event. `updateCursor()` gates on `userInteractKey.getState(editor.state)` in addition to `editor.isFocused` to prevent flashing at position 1 before the clicked position settles after a click.

### FocusCustomizationView (`Sources/Views/Settings/FocusCustomizationView.swift`)

Settings sub-page for focus mode appearance. Accessed via "Customize focus mode" in `SettingsView`. All changes post `.focusCustomizationChanged` so `EditView` re-applies customizations live.

| AppStorage key | Type | Default | Effect |
| --- | --- | --- | --- |
| `focusFloating` | Bool | true | Adds 27px vertical padding + rounded corners to the 820px column |
| `focusWallpaperPath` | String | "" | Path to a wallpaper image in `~/Library/Application Support/BlobTxt/` |
| `focusDimness` | Double | 0.5 | `--focus-dimness` CSS variable (0–1 opacity of the black overlay) |
| `focusBlur` | Double | 0.0 | `--focus-blur` CSS variable (0–20px blur on the wallpaper layer) |

Wallpaper flow: user picks an image via `NSOpenPanel` → file is copied to `~/Library/Application Support/BlobTxt/wallpaper.{ext}` → path saved to `focusWallpaperPath` → `.focusCustomizationChanged` posted → `EditorBridge.applyFocusModeCustomizations` calls `setFocusWallpaper(dataURL:)` with a `blobtxt://wallpaper?t=<timestamp>` URL → JS sets `--focus-wallpaper` → WebKit fetches via `WallpaperSchemeHandler`.

### LinkDialogView (`Sources/Views/Editor/LinkDialogView.swift`)

Sheet for adding or editing a hyperlink. Presented by `EditView` when `bridge.showLinkDialog` is true. Title reads "ADD HYPERLINK" or "EDIT HYPERLINK" depending on whether `bridge.pendingLinkHref` is nil. URL input uses `LinkPlainTextField` (local `NSViewRepresentable`); pressing Return confirms. Action buttons: "Remove" (edit mode only) · "Cancel" · "Add"/"Update" (disabled while field is empty). On confirm, prepends `https://` if no protocol prefix is present (`http://`, `https://`, and `mailto:` pass through unchanged), then calls `bridge.setLink(url:)`.

## Sidebar

### UX Overview

The sidebar has two parts: a floating island of buttons anchored to the bottom-left of the window, and an expandable panel above it. The four panels are mutually exclusive — activating one while another is open switches panels rather than closing the sidebar.

The four panels: File Navigator (two-level project tree with full drag-reorder), Blob Outline (heading structure of the open blob), Search (cross-blob or single-blob search with find-and-replace), and Metadata (title, author, word count, last modified for the open blob).

### SidebarView and FloatingIslandView

`SidebarView` (`Sources/Views/Sidebar/SidebarView.swift`) is a 270pt column. When `isSidebarOpen` is true, the active panel renders as a floating rounded rectangle inset within the column, with 8pt margins on all sides and 56pt of bottom clearance for the island.

`SidebarPanel` cases: `.navigator` / `.blobOutline` / `.search` / `.metadata`. `togglePanel()` enforces mutual exclusivity. Notification listeners (`.toggleNavigator`, `.toggleSearch`, `.toggleOutline`, `.toggleMetadata`) live in `SidebarView` so they remain active even when no panel is open.

`FloatingIslandView` (`Sources/Views/FloatingIslandView.swift`) is a `surfaceSunken` rounded rect overlaid on the bottom-left via `.overlay(alignment: .bottomLeading)` in `ContentView`. It is hidden in focus mode. Collapsed state (no panel open, not hovered): 40×40pt, command icon only. Expanded state (panel open or hovered): 254×40pt, all four buttons visible. A sliding `surfaceRaised` indicator sits behind the hovered button. When a panel is open, the active button gets a full-opacity `metaIndication` background.

### FileNavigatorView (`Sources/Views/Sidebar/FileNavigatorView.swift`)

`expandedFolderIDs` and `selectedFolderID` are `@Binding` props owned by `ContentView` (passed through `SidebarView`) so expansion state survives panel toggles and focus mode entry/exit. The state resets when `selectedProjectID` changes.

Contents: project header with back button, expandable folders with nested blobs, root-level blobs. Full drag-reorder at every level. Dragged items are held at `height: 0 / opacity: 0` rather than removed, preventing gesture cancellation. `ItemFrameKey` is a `PreferenceKey` used to track item frame positions for ghost placeholder placement during drags. Context menus support rename and delete for folders and blobs, and move-to-root for blobs.

### BlobOutlineView (`Sources/Views/Sidebar/BlobOutlineView.swift`)

Displays the heading structure of the currently open blob. Shows "No blob open." or "No headings." as appropriate. Heading rows are indented by level (12pt per level after H1) and collapsible when they have children. The active heading (currently in the editor viewport) is highlighted with a background tint and a 2pt left accent bar.

Clicking a row posts `scrollToOutlineHeading` (carrying the heading index), which `EditView` forwards to `bridge.scrollToHeading(index:)`. The JS side sends `headingVisible` messages to Swift; `EditorBridge` re-posts them as `activeHeadingChanged` for `BlobOutlineView` to update `activeHeadingIndex`. Data reloads via `store.loadBlobHeadings(blobID:in:)` whenever `activeBlobID` or `selectedProjectID` changes.

### BlobSearchView (`Sources/Views/Sidebar/BlobSearchView.swift`)

Search across all blobs in the current context or within the open blob, with find-and-replace.

The toggle state is context-derived: when no blob is open, it is always OFF and disabled; when a blob is open, it defaults OFF. Toggling ON scopes search to the open blob and re-runs it; toggling OFF clears snippet results and posts `clearSearchHighlights`.

In all-blobs mode, results are blob-level cards with a `metaIndication`-colored match count badge. In single-blob mode, one card appears per occurrence with up to 60 characters of surrounding context; the matched term is highlighted in the card via `AttributedString`. Tapping a snippet card posts `scrollToSearchResult` with the occurrence index.

When in single-blob mode, searching calls `bridge.searchAndHighlight(query:)`, which creates ProseMirror decorations (`search-highlight` CSS class) on every match via `SearchHighlightExtension` in `main.js`. `bridge.scrollToSearchResult(index:)` scrolls the Nth decorated range into view.

Replace-all shows a confirmation alert with the occurrence and blob count, then calls `store.replaceAllInBlobs(blobIDs:in:find:replace:)`. If the open blob was modified, `reloadEditorContent` is posted so `EditView` reloads the editor content via `bridge.setContent(_:)`.

### BlobMetadataView (`Sources/Views/Sidebar/BlobMetadataView.swift`)

Shows per-blob metadata for the open blob. Fields: Title (overrides the content-derived title in the file navigator, print jobs, and DOCX exports), Author (used in print jobs and DOCX exports), Words (excluding footnote nodes), and Modified (relative timestamp: "just now", "N minutes ago", "N hours ago", or a formatted date for ≥ 1 day).

Both fields are disabled when no blob is open. Values are saved via `store.updateBlobMetadata(blobID:in:title:author:)` on Enter (`onSubmit`) and when the panel disappears or the active blob changes. `loadBlobExcerpt` checks `blob.title` after extracting the content-derived title and overrides it if set, so the navigator, print, and export all respect the metadata title automatically.
