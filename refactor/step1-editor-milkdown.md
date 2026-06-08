# Step 1: Editor Rebuild (Milkdown)

Status: complete. Build verified clean (`npm run build`, 471 kB output).

## 1. What Changed

### 1.1. `editor-src/package.json`

All TipTap packages removed: `@tiptap/core`, `@tiptap/starter-kit`, `@tiptap/extension-*`, `tiptap-footnotes`, `tiptap-text-direction`.

Replaced with:

| Package | Role |
|---|---|
| `@milkdown/core` | Editor lifecycle, context system (`rootCtx`, `editorViewCtx`, `schemaCtx`) |
| `@milkdown/preset-commonmark` | CommonMark nodes and marks with their commands |
| `@milkdown/preset-gfm` | GFM extensions including footnote nodes (`footnote_reference`, `footnote_definition`) |
| `@milkdown/plugin-history` | Undo/redo |
| `@milkdown/plugin-listener` | Lifecycle callbacks (`mounted`, `updated`, `selectionUpdated`, `focus`, `blur`) |
| `@milkdown/prose` | ProseMirror internals re-exported (`Plugin`, `PluginKey`, `TextSelection`, `Decoration`, `DecorationSet`) |
| `@milkdown/utils` | High-level helpers (`callCommand`, `getMarkdown`, `replaceAll`, `$prose`) |

### 1.2. `editor-src/editor.html`

Removed the `<button id="underline-btn">` element. No other structural changes.

### 1.3. `editor-src/src/style.css`

Removed the `.fmt-btn.u-style` rule (the underline button's text-decoration styling). No other changes; all `.ProseMirror` content styles carry over unchanged because Milkdown is also ProseMirror-backed.

### 1.4. `editor-src/src/main.js`

Full rewrite. The structure mirrors the old file but every editor API call is Milkdown-based.

**Initialization.** `new Editor({...})` is replaced by the async `Editor.make().config(...).use(...).create()` chain. The editor mounts into `#editor` via `ctx.set(rootCtx, ...)`. Lifecycle callbacks are registered via `ctx.get(listenerCtx)` in a config block.

**ProseMirror plugins.** `SearchHighlightExtension` and `UserInteractionExtension` were TipTap `Extension.create()` wrappers that called `addProseMirrorPlugins()`. They are now plain ProseMirror `Plugin` instances, registered into Milkdown via `$prose(ctx => plugin)` and passed to `.use()`. The plugin logic itself (decoration state, keystroke gating, click handler) is identical to before.

**Footnote clipboard.** The old `FootnoteClipboardExtension` solved two problems: a paste-side schema-fitting bug specific to `tiptap-footnotes`, and a copy-side missing-definitions bug. The paste problem disappears because Milkdown/remark handles footnote Markdown natively without schema fitting. The copy-side handler is replaced by a simple DOM `copy` event listener that works on Markdown strings: when the selection contains `[^N]` references, it reads the full document Markdown via `editor.action(getMarkdown())`, finds the matching `[^N]: ...` definition lines, and appends them to the clipboard text.

**Footnote insertion.** There is no dedicated Milkdown command for inserting a footnote reference. The `addFootnoteReference()` function builds the reference and definition nodes directly via ProseMirror transactions: it scans the document for the highest integer label in use, picks `next = max + 1`, inserts a `footnote_reference` node inline at the cursor, and appends a `footnote_definition` node at the end of the document.

**`window.editorBridge`.** All methods preserved. `setContent(n)` now receives a Markdown string and calls `editor.action(replaceAll(n))`. `getContent()` is a new method (called by Swift) that returns `editor.action(getMarkdown())`. Formatting commands call `editor.action(callCommand(commandName.key, payload))` using the command keys exported from `@milkdown/preset-commonmark`. `toggleUnderline()` is removed.

**Helper functions exposed on `window`.** These are used by `toolbarInitJS`, which is injected by Swift and has no direct access to the editor module:

- `window.__ft_userInteracted()` — returns the current value of the `userInteractKey` plugin state (false until the user clicks).
- `window.__ft_stateSnapshot()` — queries the ProseMirror state and returns a plain object with boolean/integer fields (`bold`, `italic`, `heading`, `bulletList`, `orderedList`, `blockquote`, `linkActive`) for the toolbar to read.
- `window.__ft_getLinkHref()` — returns the `href` of the link mark at the cursor, or null.

**Timing note.** The `mounted` listener callback fires during `create()`, before the `editor` variable is assigned. It only posts `{ type: 'editorReady' }`, which requires no editor access, so this is safe. All other callbacks (`updated`, `selectionUpdated`, `focus`, `blur`) fire from user interactions after `create()` has resolved.

### 1.5. `BlobTxt/Sources/Views/Editor/EditorBridge.swift`

Three changes:

1. `EditorState` — `underline: Bool` field removed.

2. `stateUpdate` message handler — `underline` field removed from the `EditorState` initializer call.

3. `toggleUnderline()` method — removed.

4. `setContent(_:)`, `setContentAndScrollToTop(_:)`, `setContentAndScrollTo(_:scrollTop:)` — parameter renamed from `jsonString: String` to `markdown: String`. The JS injection pattern `var c = \(jsonString)` (which embedded a raw JSON object literal) is replaced with `var c = \(jsLiteral)` where `jsLiteral` is a properly escaped JS string literal produced by `markdownToJSLiteral(_:)`. That private helper uses `JSONSerialization.data(withJSONObject: string)` to get a UTF-8-encoded JSON string representation (including surrounding double-quotes and all escape sequences), which is valid as a JS string literal.

5. `getContent(completion:)` — evaluates `window.editorBridge.getContent()` instead of `JSON.stringify(window.editor.getJSON())`.

### 1.6. `BlobTxt/Sources/Views/Editor/WebEditorView.swift` — `toolbarInitJS`

Three changes:

1. `var ed = window.editor` removed. Active-state checks no longer call `ed.isActive(...)`.

2. `updateToolbar()` now calls `window.__ft_stateSnapshot()` to get the state object, then reads fields from it (`snap.bold`, `snap.heading`, etc.). The `setInterval(updateToolbar, 100)` polling loop is unchanged; the `ed.on('transaction', ...)` and `ed.on('selectionUpdate', ...)` subscription calls are removed (the polling is sufficient).

3. Underline button wiring (`on('underline-btn', ...)`) removed.

4. Link button click handler reads the current link href via `window.__ft_getLinkHref()` instead of `ed.getAttributes('link').href`.

## 2. What Is Not Changed

- `WKWebView`, `WebEditorView`, `WallpaperSchemeHandler`, `WeakMessageHandler` — no changes.
- All JS↔Swift message names and payloads in both directions — preserved exactly.
- `EditView.swift` — no changes (autosave, scroll restore, focus mode, link dialog all unchanged; the method signatures on `EditorBridge` are compatible).
- CSS content styles (`.ProseMirror`, headings, lists, blockquotes, footnotes, custom cursor, focus mode) — unchanged.
- Scroll position tracking, autoscroll, footnote tooltip, ⌘+click, ⌘K — logic unchanged, just re-registered under the Milkdown event model.

## 3. Known Limitations at This Stage

- Existing blobs are stored as TipTap JSON. Step 1 makes the editor expect Markdown. Opening an existing blob before running the migration script will render the raw JSON as text. Steps 1 and 2 are intended to be verified together after the migration script is run.
- The `scrollToTop()` method in `EditorBridge.swift` still calls `window.editor.commands.focus('start')`, which is a TipTap call that no longer works. It degrades gracefully (the `if(window.editor)` guard is absent here, so it would call an undefined method). This is a minor leftover to fix in Step 2 cleanup.

## 4. Verification Checklist (for when Step 2 is also done)

1. `npm run build` succeeds (already confirmed).
2. Launch app; open a `.md` blob.
3. Type text; verify bold (⌘B), italic (⌘I), headings, blockquote, bullet list, numbered list, hyperlink (⌘K), image, and footnote reference all work.
4. Verify toolbar buttons show correct active state as cursor moves through different block types.
5. Verify underline button is absent.
6. Save (⌘S), close, reopen — content round-trips correctly.
7. Focus mode, centered autoscroll, search highlight, scroll position restore.
8. Copy a selection containing a footnote reference; paste elsewhere — definition is included.
