# Refactor Phase 3

Notes: The plan doesn't address how the formatting commands and toolbar state detection get ported. Currently toolbarInitJS and sendStateUpdate() both use TipTap's API directly: ed.isActive('bold'), editor.chain().focus().toggleBold().run(), ed.on('transaction', updateToolbar). None of these exist in Milkdown. The plan says the toolbar is largely unchanged, but the JS underneath it has to be substantially rewritten. Milkdown exposes ProseMirror state directly, so the equivalents are there — they just need to be specified. This affects every formatting button.

Similarly, addFootnoteReference() currently calls editor.chain().focus().addFootnote().run() from tiptap-footnotes. The plan retires tiptap-footnotes but says nothing about what the Milkdown-side footnote insertion command looks like. That needs to be worked out.

## 1. Overview of Changes Thus Far

Data-related structs and functions have been updated for the Markdown migration. Of primarily interest to the current phase are the changes that were made to `ProjectStore`, which handles CRUD operations and content extraction services for blob files. All the sidebar panels, with the exception of the navigator, have been stripped and replaced with a blank placeholder, such that this pass does not need to worry about back-compatibility. The navigator has been replaced with a very simple, bare-minimum version for now, which simply sets `activeEditorURL` to a blob's file URL, which `ContentView` observes to show `EditView`.

## 2. Overview of Current Editor Codebase
### 2.1. UX Overview

The editor is a rich text editor built on TipTap (based on ProseMirror), hosted inside a WKWebView. The toolbar provides: bold, italic, underline, blockquote, heading levels (H1–H3), bullet and ordered lists, hyperlinks, and image insertion.

The editor autosaves 5 seconds after a change, and also saves on ⌘S, on ESC, and when the app quits. A small "Saving..." / "Saved!" island confirms save state.

Focus mode (⌘M or View → Focus Mode) hides the sidebar, constrains the toolbar and editor to a centered 820px column, and flanks it with black gutters. ESC exits focus mode when active rather than closing the editor. When both focus mode and fullscreen are on, the fullscreen customizations from "Settings" → "Customize focus mode" activate: a floating editor panel with rounded corners, a wallpaper image behind the gutters, and adjustable dimness and blur.

### 2.2. Entry and Shell

`Sources/App/BlobTxtApp.swift` is the `@main` entry point. It installs `ProjectStore` and `AppColors` as environment objects, wires a ⌘S `saveDocument` notification, flushes a save on app quit via `AppDelegate` (with a 600ms sleep to give the async save time to complete), and registers View → Focus Mode (⌘M) via `CommandGroup` which posts `.toggleFocusMode`. Also registers font size shortcuts (⌘+/⌘-) and sidebar toggles (⌘E/⌘F/⌘O). `AppDelegate.applicationDidFinishLaunching` installs an `NSEvent` monitor to intercept ⌘E at the app level — necessary because `NSTextView.useSelectionForFind:` consumes it before the SwiftUI menu shortcut fires when a text or web view holds focus.

`Sources/Views/ContentView.swift` is the root layout. `SidebarView` sits on the left (hidden when `isFocusMode` is true). On the right, either a "Open a document" placeholder (no blob active) or `EditView` (when `activeBlobID != nil`) renders inside a `ZStack` over the surface background. `ContentView` owns `isFocusMode` and `isFullScreen`; it listens for `.toggleFocusMode`, tracks fullscreen via `NSWindow` notifications, and resets focus mode when the editor closes. On `isFocusMode` or `isSidebarOpen` change, it drops `editorOpacity` to 0 then fades it back in over 300ms to hide the layout shift.

### 2.3. EditView (`Sources/Views/Editor/EditView.swift`)

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

### 2.4. WebEditorView (`Sources/Views/Editor/WebEditorView.swift`)

`NSViewRepresentable` wrapping `WKWebView` that loads `Resources/editor.html`.

Injection timing:
- Document-start: color CSS variables (prevents flash)
- Document-end: toolbar wiring JavaScript (`toolbarInitJS`) — wired after TipTap modules load

`toolbarInitJS` wires click handlers for all toolbar controls and a ⌘K keydown listener on the editor DOM that posts `insertLink` to Swift. Uses `WeakMessageHandler` to prevent a retain cycle between `WKUserContentController` and `EditorBridge`.

Registers `WallpaperSchemeHandler` on the `WKWebViewConfiguration` for the `blobtxt://` custom URL scheme. When WebKit requests `blobtxt://wallpaper?t=<timestamp>`, the handler reads the file at `focusWallpaperPath` from UserDefaults on a background thread and streams the bytes back. The timestamp busts WebKit's cache when the wallpaper is replaced. Updates auto-scroll mode, font, and image half-width on settings changes via the coordinator.

### 2.5. EditorBridge (`Sources/Views/Editor/EditorBridge.swift`)

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

### 2.6. Editor Source (`editor-src/`)

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

### 2.7. FocusCustomizationView (`Sources/Views/Settings/FocusCustomizationView.swift`)

Settings sub-page for focus mode appearance. Accessed via "Customize focus mode" in `SettingsView` (which need not be touched in the present pass). All changes post `.focusCustomizationChanged` so `EditView` re-applies customizations live.

| AppStorage key | Type | Default | Effect |
| --- | --- | --- | --- |
| `focusFloating` | Bool | true | Adds 27px vertical padding + rounded corners to the 820px column |
| `focusWallpaperPath` | String | "" | Path to a wallpaper image in `~/Library/Application Support/BlobTxt/` |
| `focusDimness` | Double | 0.5 | `--focus-dimness` CSS variable (0–1 opacity of the black overlay) |
| `focusBlur` | Double | 0.0 | `--focus-blur` CSS variable (0–20px blur on the wallpaper layer) |

Wallpaper flow: user picks an image via `NSOpenPanel` → file is copied to `~/Library/Application Support/BlobTxt/wallpaper.{ext}` → path saved to `focusWallpaperPath` → `.focusCustomizationChanged` posted → `EditorBridge.applyFocusModeCustomizations` calls `setFocusWallpaper(dataURL:)` with a `blobtxt://wallpaper?t=<timestamp>` URL → JS sets `--focus-wallpaper` → WebKit fetches via `WallpaperSchemeHandler`.

### 2.8. LinkDialogView (`Sources/Views/Editor/LinkDialogView.swift`)

Sheet for adding or editing a hyperlink. Presented by `EditView` when `bridge.showLinkDialog` is true. Title reads "ADD HYPERLINK" or "EDIT HYPERLINK" depending on whether `bridge.pendingLinkHref` is nil. URL input uses `LinkPlainTextField` (local `NSViewRepresentable`); pressing Return confirms. Action buttons: "Remove" (edit mode only) · "Cancel" · "Add"/"Update" (disabled while field is empty). On confirm, prepends `https://` if no protocol prefix is present (`http://`, `https://`, and `mailto:` pass through unchanged), then calls `bridge.setLink(url:)`.

## 3. Overview of Planned Changes
### 3.1. Replacing the Engine

Replace TipTap with **Milkdown**. Milkdown is a WYSIWYG rich text editor built on ProseMirror, designed from the ground up with Markdown as the canonical format. It uses remark under the hood for parsing and serializing, which gives us well-tested footnote support (via remark-gfm, which includes GitHub-style footnotes) and reliable round-trip fidelity for all standard nodes.

WKWebView and the Swift bridge pattern are unchanged. `window.editorBridge` remains the API surface between JS and Swift. The overall pipeline shape is the same: `editorReady` → `setContent` → edit → `getContent` → `saveBlobContent`.

Underline formatting is retired. There is no standard Markdown syntax for underline, and it is not worth encoding as HTML in `.md` files. It is dropped from the toolbar and from the data model.

### 3.2. What Is Retired

- TipTap and all `@tiptap/*` packages
- `tiptap-footnotes` (replaced by Milkdown/remark footnote handling)
- `FootnoteClipboardExtension` paste-side workaround (remark handles pasted footnote Markdown correctly without schema-fitting problems)
- `UserInteractionExtension` as a TipTap extension (replaced by a Milkdown plugin; see 3.4)
- `SearchHighlightExtension` as a TipTap extension (replaced by a Milkdown plugin; see 3.4)
- Underline formatting: the toolbar button and its `underline-btn` wiring in `toolbarInitJS`; `toggleUnderline()` in `EditorBridge.swift`; `var underline` in `EditorState` and the `underline:` field in the `stateUpdate` handler; and any underline-related CSS
- `TaskList` and `TaskItem` extensions (unused in practice)
- DOCX export (out of scope for this refactor)

## 4. Markdown Format

`setContent` accepts a Markdown string; `getContent` returns a Markdown string. The conversion between Markdown and Milkdown's internal ProseMirror representation happens entirely inside JS. Swift reads/writes `.md` files and passes raw Markdown strings across the bridge — it never sees or interprets the internal document format.

### 4.1. Footnotes

Footnotes use sequential integer IDs in the file:

```markdown
Here is some text with a note.[^1]

[^1]: The footnote content goes here.
```

This is clean, portable Markdown compatible with CommonMark/GFM footnote syntax. No UUID-based footnote identity is needed. The integer ID is stable within a file edit session; it is re-derived from position on every save. This renumbering is not built into remark-gfm — it must be implemented as a custom remark unified plugin that runs during serialization (i.e., as part of `getContent()`). The plugin walks `footnoteReference` nodes in document order, builds an `oldID → newSequentialNumber` map, and rewrites both references and definitions to match.

### 4.2. Features Rebuilt as Milkdown Plugins

**Custom cursor.** The div-based cursor replacement is reimplemented as a Milkdown plugin. The coordinate logic (`coordsAtPos`, `getBoundingClientRect`) is unchanged. Registration changes from a TipTap extension to a Milkdown plugin slot.

**Keystroke gating.** The behavior of blocking keystrokes until the user has clicked to establish a cursor position is preserved. It is reimplemented as a Milkdown ProseMirror plugin. The toolbar no longer needs this flag for state gating — Milkdown exposes editor state directly.

**Centered autoscroll.** The `doCenteredScroll` function is unchanged. It is registered via Milkdown's `onUpdate` listener rather than TipTap's `onUpdate` callback.

**Footnote tooltip and click-to-scroll.** DOM event listeners on the editor container. Logic unchanged; registration unchanged.

**Footnote clipboard — copy side.** When copying a selection that contains `[^N]` inline markers, the referenced `[^N]: definition` blocks are outside the selection (they live at doc end). A custom copy handler intercepts the copy event, scans the selection for markers, and appends the matching definitions to the clipboard Markdown. This is simpler than the TipTap version — string operations on Markdown rather than HTML DOM manipulation and ProseMirror serialization.

**Footnote clipboard — paste side.** Pasting from another document can introduce footnote IDs that conflict with those already in the destination document. Because both the inline references and definitions share the same identifier string, a conflict causes the pasted footnote's definition to be silently dropped when the file is next parsed. A ProseMirror `handlePaste` plugin prevents this. If the clipboard plain text contains no `[^` markers, the plugin skips processing and returns `false` to let Milkdown's default paste handler proceed. Otherwise: walk the current ProseMirror doc to find the maximum existing footnote ID (`N_a`; zero if none); scan the clipboard Markdown for footnote IDs by order of first appearance and renumber them `N_a + 1` through `N_a + N_b` (rewriting both inline references and definitions); then parse and insert the modified Markdown normally. If any remapping was done, post a `saveDocument` message to Swift immediately after insertion rather than waiting for the 5-second autosave timer, so the renumbering-on-save plugin (see 4.1) resolves the temporary high IDs back to clean sequential numbers right away.

### 4.3. Features Unchanged

**Scroll position persistence.** The debounced scroll event listener posting `scrollPositionChanged` to Swift is pure DOM code, independent of the editor framework. Unchanged.

**Focus mode.** `setFocusMode` toggles a CSS class on `document.body`. Unchanged. The wallpaper, dimness, blur, and floating panel customizations are out of scope for this refactor.

**JS↔Swift message types.** All message names and payloads in both directions are preserved, with one exception: the `copyAll` message. The JS `copyAll` handler previously sent both `html` and `text` fields; after the migration it sends only `text`, containing the Markdown string from `editor.action(getMarkdown())`. Everything put on the clipboard is Markdown. `EditorBridge.swift`'s `copyAll` case is updated to write only plain text.

**Autosave debounce logic.** `EditorBridge.swift` and `EditView.swift` are unchanged except as noted below.

### 4.4. Swift Bridge Changes

`setContent` in `main.js` calls Milkdown's `replaceAll(markdown)` action instead of `editor.commands.setContent`. `getContent` returns `editor.action(getMarkdown())` (Milkdown's serializer action).

`EditorBridge.swift` changes:

- `getContent(completion:)` evaluates `window.editorBridge.getContent()` (a thin wrapper added to `window.editorBridge`) instead of `JSON.stringify(window.editor.getJSON())`.
- `setContent(_:)` and its scroll variants must pass the Markdown string as a JS string literal rather than as a raw JSON value. The current pattern (`var c = \(jsonString)`) works for JSON objects but not for Markdown strings. Use `JSONSerialization` to produce a properly escaped JS string literal from the Swift `String`.
- Remove `toggleUnderline()`.
- Remove `var underline` from `EditorState` and the `underline:` field from the `stateUpdate` handler.
- Update the `copyAll` handler to write only plain text (Markdown string) to the clipboard, dropping the HTML branch.
