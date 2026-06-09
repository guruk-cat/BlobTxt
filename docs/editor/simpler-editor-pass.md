# Plan: Simpler Markdown Editor (CodeMirror 6)

## 1. Overview

This pass replaces the Milkdown/ProseMirror WYSIWYG editor with a CodeMirror 6 Markdown source editor. CodeMirror 6 is a code editor library: the document is always the raw Markdown string, and syntax indication (heading sizes, bold display, dimmed punctuation) is applied as visual decoration without any round-trip serialization.

This eliminates the custom footnote schema plugins, the paste normalization plugin, the renumbering pass, the custom cursor, and all toolbar formatting commands — all of which arose from the gap between the ProseMirror document model and raw Markdown.

The toolbar is retired along with all formatting commands. The link dialog is also removed; links are typed directly as `[text](url)`. Image insertion is removed; images appear as their raw Markdown source text.

## 2. Package Changes
### 2.1. Packages to Remove

The following are removed from `package.json`:

- `@milkdown/core`, `@milkdown/preset-commonmark`, `@milkdown/plugin-listener`, `@milkdown/plugin-history`, `@milkdown/prose`, `@milkdown/utils`
- `remark-gfm`
- `unist-util-visit`

### 2.2. Packages to Add

- `@codemirror/state` — editor state, transactions, effects, and state fields
- `@codemirror/view` — `EditorView`, decorations, keymaps, and update listener
- `@codemirror/lang-markdown` — Markdown language mode, including GFM extensions
- `@codemirror/language` — `HighlightStyle` and `syntaxHighlighting`
- `@codemirror/commands` — built-in keymaps (default editing, history, indentation)
- `@lezer/highlight` — token tag definitions used in `HighlightStyle.define()`

## 3. Web Layer
### 3.1. HTML Structure

The toolbar div and all its children are removed. The three remaining elements stay:

```html
<body>
  <div id="focus-bg"></div>
  <div id="editor"></div>
</body>
```

### 3.2. Editor Initialization

CodeMirror initializes synchronously (there is no async plugin setup to await). An `EditorView` is created with the following extensions and mounted to `#editor`:

- `markdown({ extensions: [GFM] })` — Markdown language support, including footnote syntax (`[^label]` and `[^label]: ...`)
- `syntaxHighlighting(highlightStyle)` — the custom `HighlightStyle` described in section 3.3
- `headingLineDecorations` — a `ViewPlugin` that applies heading and blockquote line classes (section 3.4)
- `history()` — undo/redo stack
- `keymap.of([...defaultKeymap, ...historyKeymap])` — standard editing keys
- `EditorView.lineWrapping` — soft wraps long lines
- `EditorView.updateListener.of(...)` — posts `documentChanged` to Swift when `update.docChanged` is true
- A `domEventHandlers` extension — handles the debounced scroll listener and ⌘+click link opening

After creating the view, `editorReady` is posted to Swift.

### 3.3. Syntax Highlighting

Syntax indication is defined with `HighlightStyle.define()`. This maps lezer token tags (from `@lezer/highlight`) to CSS style objects. The mapping below targets the original color variables.

All Markdown formatting punctuation (`#`, `*`, `**`, `[`, `]`, `(`, `)`, `` ` ``, `>`) is emitted by the lezer Markdown parser as `tags.processingInstruction`. These characters get `color: var(--text-muted)`.

Heading content is tagged `tags.heading1`, `tags.heading2`, `tags.heading3`. These get `color: var(--text-heading)` and font sizes of `2em`, `1.6em`, and `1.3em`, matching the current values. The `#` marks remain muted.

Bold content (`tags.strong`) gets `fontWeight: bold`. Italic content (`tags.emphasis`) gets `fontStyle: italic`. Their surrounding markers remain muted.

Link text (`tags.link`) stays body color. Link URLs (`tags.url`) get `var(--meta-indication)` to match the current link color.

Footnote labels in both inline references and definitions are emitted as GFM footnote nodes; their labels get `var(--meta-indication)`. Exact tag mappings may need adjustment during implementation.

Anything not mentioned here but encountered during implementation simply gets `--text-body` color.

### 3.4. Line Decorations

Some elements require styling an entire line rather than individual tokens. A `ViewPlugin` walks visible syntax tree nodes and attaches `Decoration.line()` instances:

- Heading lines get classes `cm-md-h1`, `cm-md-h2`, `cm-md-h3`, so the `#` marker and the heading text share the same line height.
- Blockquote lines get `cm-md-blockquote`, which CSS uses to apply the left border.
- Footnote definition lines get `cm-md-footnote-def` for the smaller font size.

### 3.5. Swift Bridge

`window.editorBridge` keeps the same shape for functions Swift calls. Methods removed are those that were toolbar-specific:

- `toggleBold`, `toggleItalic`, `toggleBlockquote`, `toggleBulletList`, `toggleOrderedList`, `setHeading`
- `setLink`, `unsetLink`
- `addFootnoteReference`
- `copyAll`
- `insertImage`

Remaining methods and their implementations:

- `setContent(markdown)` — `view.dispatch({ changes: { from: 0, to: view.state.doc.length, insert: markdown } })`
- `getContent()` — `return view.state.doc.toString()`
- `setAutoScrollMode(m)` — same logic as before (adjusts `paddingBottom` for centered mode)
- `setFocusMode(enabled)` — toggles `focus-mode` on `document.body`, unchanged
- `setFocusModeCustomizations(enabled, floating, dimness, blur)` — unchanged
- `setFocusWallpaper(dataURL)` — unchanged

Posts to Swift are also reduced. `stateUpdate`, `copyAll`, `closeEditor`, `insertLink`, `insertImage`, and `headingVisible` messages are removed. Remaining posts: `editorReady`, `documentChanged`, `scrollPositionChanged`, and `openURL`.

### 3.6. Link Opening

The current editor listens for ⌘+click on rendered `<a href>` elements. CodeMirror renders links as styled spans with no anchor element. The replacement uses a CM `domEventHandlers` click handler: on ⌘+click, the click position is converted to a document offset via `view.posAtCoords()`, the syntax tree is queried for a URL node at that offset, the URL string is extracted from `view.state.doc.sliceString(from, to)`, and `openURL` is posted to Swift.

## 4. CSS

### 4.1. Sections to Remove

- All toolbar CSS: `#toolbar`, `#toolbar-fmt`, `#toolbar-chrome`, `.fmt-btn`, `.menu-btn`, `.dropdown`, `.dropdown-item`, `.dropdown-sep`, `.chrome-btn`, and associated state classes
- Custom cursor CSS: `#custom-cursor` rule and `@keyframes cursor-blink`
- `.ProseMirror` and all `.ProseMirror …` content styles
- `sup.footnote-ref` and `.footnote-def` block styles (replaced by CM line decoration classes)
- `.footnote-tooltip` and `.footnote-tooltip[hidden]` — tooltip is not implemented in this pass and has no placeholder HTML, so the CSS is removed rather than retained

### 4.2. New Editor Base Styles

The `#editor` container CSS is unchanged. CodeMirror mounts as `.cm-editor` inside it, containing `.cm-scroller` and `.cm-content`. The following base overrides are added:

```css
.cm-editor {
  height: 100%;
  outline: none;
  background: transparent;
}

.cm-content {
  max-width: 820px;
  margin: 0 auto;
  color: var(--text-body);
  font-family: Menlo, Consolas, "Courier New", monospace;
  font-size: 22px;
  line-height: 2;
  caret-color: var(--meta-indication);
  padding: 0;
}

.cm-scroller {
  overflow: visible;
}
```

Scrolling is handled by `#editor`, not by `.cm-scroller`. The `overflow: visible` override keeps CM from adding its own scroll container.

The `applyEditorStyle` function in `EditorBridge.swift` currently targets `.ProseMirror`. It needs to target `.cm-content` instead. Heading font-size overrides use `.cm-line.cm-md-h1`, `.cm-line.cm-md-h2`, `.cm-line.cm-md-h3`.

### 4.3. Syntax Indication Styles

Token-level styles (color, weight, style) live in `HighlightStyle.define()` in `main.js`. Line-level styles live in `style.css`:

```css
.cm-line.cm-md-blockquote {
  border-left: 3px solid var(--text-muted);
  padding-left: 1em;
}

.cm-line.cm-md-footnote-def {
  color: var(--text-muted);
  font-size: 0.85em;
  line-height: 1.6;
}

.cm-line.cm-md-footnote-def:first-of-type {
  border-top: 1px solid var(--text-muted);
  margin-top: 2.5em;
  padding-top: 1em;
}
```

The `.search-highlight` class name stays the same; only the decoration mechanism changes.

The `::selection` rule is unchanged.

### 4.4. Retained Sections

The following CSS sections are retained with no or minimal changes:

- CSS custom properties (`:root` block)
- Focus mode: `.focus-mode`, `.focus-custom`, `.floating`, `#focus-bg`, and all associated rules. The previous rule constraining `#toolbar` and `#editor` to 820px in focus mode loses the `#toolbar` part but otherwise stays the same.

## 5. Swift Layer

### 5.1. EditorBridge.swift

The following are removed:

- `EditorState` struct
- `@Published var editorState`, `@Published var showLinkDialog`, `@Published var pendingLinkHref`
- `private var pendingImageInsert`
- `toggleBold`, `toggleItalic`, `toggleBulletList`, `toggleOrderedList`, `toggleBlockquote`, `setHeading`
- `setLink`, `unsetLink`
- `addFootnoteReference`
- `copyAll`
- `insertImage(src:)`, `openImagePicker`
- `refocusWebView`
- `static func writeToClipboard`
- `searchAndHighlight`, `scrollToSearchResult`, `clearSearchHighlights`
- `scrollToHeading`
- Message handling cases: `stateUpdate`, `copyAll`, `closeEditor`, `insertLink`, `insertImage`, `headingVisible`
- Notification names: `scrollToOutlineHeading`, `activeHeadingChanged`, `searchAndHighlight` (the name extension), `scrollToSearchResult` (the name extension), `clearSearchHighlights` (the name extension)

The following are kept without change:

- `isReady`, `isDirty`, `lastScrollPosition`, `onClose`
- `setContent`, `setContentAndScrollToTop`, `setContentAndScrollTo`, `getContent`
- `setAutoScroll`, `setFocusMode`, `applyFocusModeCustomizations`, `setFocusWallpaper`
- `applyColors`, `setFontSize`, `setFontFamily`, `setImageHalfWidth`
- `selectAll`
- `markClean`
- Message handling: `editorReady`, `documentChanged`, `scrollPositionChanged`, `openURL`
- Notification names: `reloadEditorContent`, `toggleFocusMode`, `focusCustomizationChanged`
- `WallpaperSchemeHandler`, `WeakMessageHandler`
- `URL.mimeType` extension

`applyEditorStyle` is modified to target `.cm-content` and heading line classes instead of `.ProseMirror`.

### 5.2. EditView.swift

The link dialog sheet binding is removed:

```swift
// Remove:
.sheet(isPresented: $bridge.showLinkDialog) { LinkDialogView(bridge: bridge) }
```

The `.onReceive` handlers for `.scrollToOutlineHeading`, `.searchAndHighlight`, `.scrollToSearchResult`, and `.clearSearchHighlights` are also removed. Their senders (`BlobOutlineView`, `BlobSearchView`) were deleted in Pass 0; the handlers were left as stubs pending panel rebuilds. They are cut here since the bridge methods they called are being removed.

Everything else is unchanged: the load lifecycle, the save lifecycle, focus mode observers, scroll persistence, and the key monitor for ESC / ⌘M / ⌘A.

### 5.3. WebEditorView.swift

`static let toolbarInitJS` and the `WKUserScript` that injects it at document-end are removed. The document-start color injection script, the `Coordinator`, and all settings propagation remain unchanged.

### 5.4. LinkDialogView.swift

Removed entirely.

## 6. Behavior Changes

The following behaviors change deliberately from the current editor:

- The toolbar is removed. Formatting is typed as Markdown syntax.
- Images are not rendered inline. Image syntax (`![alt](url)`) appears as its raw source text. Image insertion is unavailable.
- Links are not rendered as anchor elements. ⌘+click still opens a link, but by reading the URL from the syntax tree position rather than from an anchor element's `href`.
- The link dialog is removed. Links are inserted by typing `[text](url)` directly.
- Footnote IDs are not renumbered on save. The user is responsible for unique labels.
- Pasted Markdown with conflicting footnote labels is not normalized. This is an acceptable trade-off given the rarity of cross-document footnote pasting.
