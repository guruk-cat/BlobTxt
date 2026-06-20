# Pass 4 Log: Editor Rebuild (CodeMirror 6)

## 1. Overview

This pass replaced the Milkdown/ProseMirror WYSIWYG editor with a CodeMirror 6 plain-text Markdown editor. The toolbar, link dialog, image insertion, footnote renumbering, and all associated JS plugins were removed. The Swift bridge was stripped down to the minimal interface needed for the new editor.

## 2. Package Changes (`editor-src/package.json`)

Removed: `@milkdown/core`, `@milkdown/preset-commonmark`, `@milkdown/plugin-listener`, `@milkdown/plugin-history`, `@milkdown/prose`, `@milkdown/utils`, `remark-gfm`, `unist-util-visit`.

Added: `@codemirror/state`, `@codemirror/view`, `@codemirror/lang-markdown`, `@codemirror/language`, `@codemirror/commands`, `@lezer/highlight`, `@lezer/markdown`.

Note: `GFM` is exported by `@lezer/markdown`, not by `@codemirror/lang-markdown`. The latter only re-exports `markdown`, `markdownLanguage`, and a few command helpers. `@lezer/markdown` was added as an explicit dependency accordingly.

## 3. Web Layer
### 3.1. `editor.html`

Removed the entire `#toolbar` div and its contents, and the `#footnote-tooltip` div. The body now contains only `#focus-bg` and `#editor`.

### 3.2. `main.js`

Complete rewrite. The new file:

- Creates a `CodeMirror EditorView` mounted to `#editor`, with extensions for Markdown language (GFM dialect), `HighlightStyle`-based syntax indication, a `headingLineDecorations` `ViewPlugin`, history, default keymaps, line wrapping, an update listener, and a `domEventHandlers` extension for ⌘+click link opening.
- Defines `HighlightStyle` mapping lezer token tags to CSS style objects. Heading font sizes are intentionally excluded here; they are set by Swift's `applyEditorStyle` so they scale with the user's font size preference.
- Defines the `headingLineDecorations` `ViewPlugin`, which walks the visible syntax tree on each update and attaches `Decoration.line()` instances with classes `cm-md-h1/h2/h3`, `cm-md-blockquote`, and `cm-md-footnote-def`.
- Implements ⌘+click link opening by resolving the click position with `view.posAtCoords()`, walking up the syntax tree to find a `URL` node, and posting `openURL` to Swift.
- Exposes `window.editorBridge` with six methods: `setContent`, `getContent`, `setAutoScrollMode`, `setFocusMode`, `setFocusModeCustomizations`, `setFocusWallpaper`. All toolbar-related methods are gone.
- Uses a `suppressDocChanged` boolean flag (set around `view.dispatch()` in `setContent`) to prevent a spurious `documentChanged` post when content is loaded programmatically.

### 3.3. `style.css`

Removed: all `#toolbar` and button CSS, `.ProseMirror` and all child rules, `sup.footnote-ref`, `.footnote-def`, `.footnote-tooltip`, `#custom-cursor` and `@keyframes cursor-blink`.

Added: `.cm-editor`, `.cm-content`, and `.cm-scroller` base overrides. `.cm-scroller { overflow: visible }` delegates scrolling to `#editor` instead of letting CodeMirror manage its own scroll container. `.cm-content` sets `caret-color: var(--meta-indication)` for the native cursor. Line decoration classes `.cm-line.cm-md-blockquote` and `.cm-line.cm-md-footnote-def` added.

Modified: focus mode rules updated to remove all `#toolbar` selectors. The floating focus mode `#editor` border-radius updated to full rounded corners (previously split with the toolbar at the top).

## 4. Swift Layer
### 4.1. `EditorBridge.swift`

Removed the `EditorState` struct and the `@Published` properties that fed it (`editorState`, `showLinkDialog`, `pendingLinkHref`). Removed `pendingImageInsert`.

Removed message handler cases: `stateUpdate`, `copyAll`, `closeEditor`, `insertLink`, `insertImage`. Retained: `editorReady`, `documentChanged`, `scrollPositionChanged`, `openURL`.

Removed methods: `toggleBold`, `toggleItalic`, `toggleBulletList`, `toggleOrderedList`, `toggleBlockquote`, `setHeading`, `setLink`, `unsetLink`, `addFootnoteReference`, `copyAll`, `openImagePicker`, `insertImage`, `refocusWebView`, `static writeToClipboard`.

Modified `applyEditorStyle` to target `.cm-content` (replacing `.ProseMirror`) and `.cm-line.cm-md-h1/h2/h3` (replacing `.ProseMirror h1/h2/h3`) for font and size overrides. Heading font sizes scale as integer multiples of the base size: `2×`, `1.6×`, `1.3×`.

### 4.2. `EditView.swift`

Removed the `.sheet(isPresented: $bridge.showLinkDialog)` modifier that presented `LinkDialogView`.

### 4.3. `WebEditorView.swift`

Removed the `toolbarInitJS` `WKUserScript` and its injection at document-end. Removed the `static let toolbarInitJS` string and the extension block that held it. The document-start color injection script and the `Coordinator` are unchanged.

### 4.4. `LinkDialogView.swift`

Deleted entirely.

## 5. Things Not Changed

The following are retained without modification and work with the new editor:

- Load lifecycle, autosave, and focus mode logic in `EditView.swift`
- `setContent`, `setContentAndScrollToTop`, `setContentAndScrollTo`, `getContent`, `markClean`, `selectAll` in `EditorBridge.swift`
- `applyColors`, `setFontSize`, `setFontFamily`, `setImageHalfWidth` in `EditorBridge.swift`
- `applyFocusModeCustomizations`, `setFocusWallpaper`, `setFocusMode`, `setAutoScroll` in `EditorBridge.swift`
- `WallpaperSchemeHandler`, `WeakMessageHandler`, `URL.mimeType` in `WebEditorView.swift`
- The document-start color injection `WKUserScript` in `WebEditorView.swift`
- The `Coordinator` and all settings propagation in `WebEditorView.swift`
- `AppColors.swift` — unchanged
- `SettingsView.swift` — unchanged
