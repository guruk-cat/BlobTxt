# Pass 2 Log: Editor Migration to Milkdown

## 1. Overview

This pass replaced the TipTap editor with Milkdown in the web editor layer. TipTap was a ProseMirror wrapper that stored documents as a JSON node tree. Milkdown is also built on ProseMirror, but it treats Markdown text as the canonical document format and uses the remark pipeline for parsing and serialization. After this pass, the editor reads and writes plain Markdown strings, which completes the storage format half of the blob migration.

The changes are concentrated in `editor-src/` (the source files for the bundled web editor) and three Swift files in the editor's bridge layer. No data model changes were made; those were completed in Pass 1.

## 2. Package Changes

`editor-src/package.json` was updated. All `@tiptap/*` and `tiptap-*` packages were removed and replaced with:

- `@milkdown/core` — editor factory and context system.
- `@milkdown/preset-commonmark` — CommonMark schema, commands, and keybindings.
- `@milkdown/plugin-listener` — content and selection change listeners with debounce.
- `@milkdown/plugin-history` — undo/redo stack.
- `@milkdown/prose` — re-exports of ProseMirror's `state`, `view`, `commands`, and `model` packages. This lets us access ProseMirror internals (plugins, decorations, transactions) without taking a separate dependency on the raw ProseMirror packages.
- `@milkdown/utils` — `callCommand`, `getMarkdown`, `$node`, `$prose` utilities.
- `remark-gfm` — GitHub Flavored Markdown extension for the remark parser. Used for footnote syntax (`[^1]` and `[^1]: …`).
- `unist-util-visit` — utility for walking remark AST nodes. Used internally by the footnote renumbering logic during development and retained as a dependency.

## 3. HTML Changes

One element was removed from `editor-src/editor.html`: the underline toolbar button (`<button class="fmt-btn u-style" id="underline-btn">U</button>`). Underline is not a Markdown formatting construct, and Milkdown's CommonMark preset has no underline mark.

No other structural changes were made to the HTML. The toolbar layout, the editor `<div>`, the footnote tooltip element, the focus-mode background element, and the custom cursor element all remain.

## 4. CSS Changes

### 4.1. Toolbar

The `.fmt-btn.u-style` rule (underline styling for the now-deleted underline button) was removed.

### 4.2. Footnotes

The old CSS targeted `a.footnote-ref`, `ol.footnotes`, and `ol.footnotes li`, which matched the DOM structure TipTap was producing. Those selectors were replaced to match the DOM structure the new Milkdown footnote plugin produces:

- `sup.footnote-ref` — the inline reference rendered as a superscript with a `data-footnote` attribute.
- `.footnote-def` — the definition block rendered as a `<div>` at the document bottom.
- `.footnote-def p` — paragraph inside the definition.
- `.ProseMirror .footnote-def:first-of-type` — adds a top border to visually separate the definition area from the body text. The `:first-of-type` selector targets the first definition div in the editor, so the separator appears only once regardless of how many footnotes exist.

## 5. JavaScript Rewrite

`editor-src/src/main.js` was rewritten from scratch. The file is the single entry point bundled by Vite into `BlobTxt/Resources/editor.html`.

### 5.1. Editor Creation

The Milkdown editor is created in an async IIFE at module load:

```javascript
const editor = await Editor.make()
  .config(ctx => { … })
  .use(commonmark)
  .use(listener)
  .use(history)
  .use(footnoteReferencePlugin)
  .use(footnoteDefinitionPlugin)
  .use(searchHighlightPlugin)
  .use(userInteractPlugin)
  .use(footnotePastePlugin)
  .create()
```

The `.config()` block does three things: sets the `rootCtx` to the `#editor` div, adds `remarkGfm` to `remarkPluginsCtx` (so the remark parser understands footnote syntax), and registers `.updated()` and `.selectionUpdated()` listeners. Both listeners call `sendStateUpdate()`, which reads active marks and block types from the ProseMirror state and posts them to Swift as a `stateUpdate` message.

The `listenerCtx.updated()` listener is debounced 200 ms and fires only when the document content changes. It both sends a state update and posts a `documentChanged` message to mark the blob dirty. The `listenerCtx.selectionUpdated()` listener fires on any selection change and sends only a state update, so the toolbar reflects cursor movement without treating a cursor move as a document edit.

After `create()` resolves, the bridge posts `editorReady` to Swift.

### 5.2. State Reading

`sendStateUpdate()` reads the ProseMirror selection state to determine which marks and block types are active at the cursor. The mark names in the Milkdown CommonMark schema are `strong` (bold), `emphasis` (italic), and `link`. Notably the italic mark is named `emphasis`, not `em`; this was verified by reading the installed package source at `node_modules/@milkdown/preset-commonmark/src/mark/emphasis.ts`.

The active heading level is found by walking `$from.node(depth)` up from the cursor and checking `node.type.name === 'heading'`. If found, `node.attrs.level` (1–3) is returned; otherwise 0 (paragraph).

`window.__ft_getActiveState()` exposes the last-sent state object to the injected toolbar script. `window.__ft_userInteracted()` returns whether the editor has received a pointer or keyboard event since the last `setContent` call (used to guard the link button). `window.__ft_getLinkHref()` returns the `href` of a link mark at the cursor position, or null if none.

### 5.3. Footnote Plugins

Milkdown's CommonMark preset does not include footnotes. remark-gfm teaches the remark parser to produce `footnoteReference` and `footnoteDefinition` AST nodes, but those nodes are unknown to Milkdown's schema, so they are silently dropped unless custom node schemas are added.

Two `$node()` plugins bridge the gap:

`footnoteReferencePlugin` defines a ProseMirror inline node (`group: 'inline'`, `inline: true`). It parses from remark's `footnoteReference` AST node (reading `node.identifier` into a `label` attribute) and serializes back to a `footnoteReference` remark node. It renders to the DOM as `<sup class="footnote-ref" data-footnote="…">[n]</sup>`.

`footnoteDefinitionPlugin` defines a ProseMirror block node (`group: 'block'`, `content: 'block+'`). It parses from remark's `footnoteDefinition` AST node, accepting the node's children as its block content. It serializes back to a `footnoteDefinition` remark node. It renders to the DOM as `<div class="footnote-def" data-footnote-id="…">`. The definition's children (typically a single paragraph) are rendered inside this div by ProseMirror's normal rendering pipeline.

A `handleClick` handler on the `footnoteReferencePlugin` intercepts clicks on `.footnote-ref` elements. It finds the matching `.footnote-def` element by label and smooth-scrolls to it. A hover tooltip is shown via the `footnote-tooltip` element with the definition's text content.

### 5.4. Footnote Renumbering

When `getContent()` is called, the Markdown returned by `editor.action(getMarkdown())` may have non-sequential footnote labels if the user deleted or reordered footnotes during editing. `renumberMarkdown(markdown)` does a two-pass string transformation: first it builds a label→integer map by scanning `[^label]` references in document order (skipping duplicates); then it replaces all `[^label]` and `[^label]:` occurrences with the reassigned numeric labels.

This approach was chosen over a remark plugin because Milkdown's remark pipeline runs only during parsing (via `remark.runSync`), not during serialization (which calls `remark.stringify` directly without running plugins). A remark plugin registered in `remarkPluginsCtx` would never fire on `getContent()`.

### 5.5. Footnote Paste Normalization

`footnotePastePlugin` is a `$prose()` ProseMirror plugin with a `transformPastedText` handler. When text is pasted, it runs `renumberMarkdown` on the pasted Markdown before Milkdown parses it. This prevents duplicate footnote labels when the user pastes content that uses the same label names as existing footnotes in the document. The renumbering assigns new labels starting from a counter that accounts for the existing labels present in the document.

### 5.6. Content Get and Set

`setContent(markdown)` replaces the entire document without marking it dirty. It uses a ProseMirror transaction that replaces the document slice and sets the cursor to the document start. The transaction carries `tr.setMeta('addToHistory', false)`, which causes Milkdown's listener plugin to skip recording this change in the debounced `updated` callback. Without this guard, every `setContent` call would immediately fire `documentChanged` and mark the blob dirty.

A `userInteractKey` plugin key is also cleared on `setContent` so that the link button guard resets.

`getContent()` calls `renumberMarkdown(editor.action(getMarkdown()))` and returns a plain Markdown string.

### 5.7. Footnote Reference Insertion

`addFootnoteReference()` is called from Swift. It finds the highest numeric label currently in the document (by scanning all `footnoteReference` nodes), assigns the next integer as the new label, and builds both a `footnoteReference` node and an empty `footnoteDefinition` node. The two nodes are inserted in a single transaction: the reference at the cursor, and the definition at the end of the document. After insertion, the cursor is placed inside the definition's paragraph so the user can immediately type the note.

An earlier draft of this function had a bug where `tr.doc.content.size` was referenced in the same chained expression that assigned `tr`, producing a `ReferenceError` because `const tr` was not yet defined. The fix was to split the chain into two `let tr = …` statements.

### 5.8. Formatting Commands

The bridge methods that invoke formatting (`toggleBold`, `toggleItalic`, `toggleBlockquote`, `toggleBulletList`, `toggleOrderedList`, `setHeading`, `setLink`, `unsetLink`, `insertImage`) all use `editor.action(callCommand(…))` with the corresponding command from `@milkdown/preset-commonmark`.

`setHeading(level)` calls `wrapInHeadingCommand` with a numeric level. When `level` is 0, the command's implementation falls into the `level < 1` branch and calls `setBlockType(paragraphSchema.type(ctx))`, converting the block back to a paragraph.

`unsetLink()` uses ProseMirror's `toggleMark` directly because Milkdown's preset-commonmark does not expose a "remove link" command. `toggleMark` with the `link` mark type and an active selection removes the mark.

### 5.9. Search and Highlight

`searchHighlightPlugin` is a `$prose()` plugin that intercepts `setMeta('search', query)` transactions. It rebuilds a `DecorationSet` containing `Decoration.inline` spans (class `search-highlight`) for every match of the query in the document. The plugin's `state.apply` checks for both the search meta and for document changes (to keep highlights valid after edits).

`searchAndHighlight(query)` dispatches the meta transaction. `scrollToSearchResult(index)` reads the decoration array from the plugin state, gets the match at the given index, and uses `editorView.domAtPos` to find the DOM node, then calls `scrollIntoView`.

### 5.10. Copy All

`copyAll()` serializes the document to Markdown via `getContent()` and sends the string to Swift as `{ type: 'copyAll', text }`. No HTML is sent. The Swift handler writes only to the `.string` pasteboard type.

## 6. Swift Bridge Changes

### 6.1. EditorBridge.swift

`EditorState` lost its `underline` field. The `stateUpdate` handler no longer reads a `underline` key. `toggleUnderline()` was removed.

The `copyAll` case in the message handler was updated to write only plain text:

```swift
case "copyAll":
    if let text = body["text"] as? String {
        Self.writeToClipboard(html: nil, plainText: text)
    }
```

`setContent`, `setContentAndScrollToTop`, and `setContentAndScrollTo` all pass the Markdown string through `JSONSerialization.data(withJSONObject:)` before embedding it in the JS call. This produces a properly quoted and escaped JS string literal and handles any special characters (backslashes, backticks, quotes, Unicode) without manual escaping.

`getContent(completion:)` now evaluates `window.editorBridge.getContent()`, which returns a Markdown string directly. Previously it evaluated a TipTap-specific JSON serialization call.

### 6.2. EditView.swift

The fallback value when loading blob content was changed from the TipTap empty-document JSON string to an empty Markdown string `""`. The same change was made in the `.reloadEditorContent` notification handler. Both paths had:

```swift
let markdown = raw.flatMap { $0.isEmpty ? nil : $0 } ?? ""
```

### 6.3. WebEditorView.swift

`toolbarInitJS` was rewritten. The old version held a reference to `var ed = window.editor` (the TipTap editor object) and called `ed.on('transaction', …)` and `ed.isActive(…)`. None of those exist in Milkdown.

The new version reads active state from `window.__ft_getActiveState()`, which is populated by `main.js`. The toolbar is updated on a 100 ms interval; the interval call is fast (object read + DOM class toggles) and produces no noticeable delay.

The link button handler calls `window.__ft_userInteracted()` before opening the dialog, and `window.__ft_getLinkHref()` to pre-populate the `href` field when the cursor is already on a link.

The underline button wiring was removed because the button no longer exists in the HTML.

## 7. Build

The Vite build was run from `editor-src/` with:

```
npm run build --cache $TMPDIR/npm-cache
```

860 modules were transformed. The output `editor.html` is approximately 420 KB and is committed to `BlobTxt/Resources/editor.html`. This file is what the app loads into the WKWebView at runtime.

## 8. Things Flagged but Not Changed

`wrapInBulletListCommand` and `wrapInOrderedListCommand` from Milkdown's preset only wrap a block in a list; they do not toggle. If the cursor is already inside a list, clicking the button again has no effect. TipTap's `toggleBulletList` would remove the list wrapper. The plan specifies using the wrap commands, so this behavioral difference is intentional for now. A future pass can add proper toggling by checking the block type before dispatching.

The same applies to `wrapInBlockquoteCommand`, which only wraps and does not un-quote.

The footnote hover tooltip shows `node.textContent`, which strips any inline formatting (bold, italic) present in the definition. Rich-text content in the tooltip would require rendering a mini DOM subtree. This is a known limitation of the current implementation.

Milkdown's `listenerCtx.updated()` fires with a 200 ms debounce after every document change. The `documentChanged` message reaching Swift is therefore delayed by up to 200 ms. The Swift autosave debounce is 5 seconds, so this extra delay is imperceptible from the user's perspective. It is noted here in case a future pass needs tighter change detection.
