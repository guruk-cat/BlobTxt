# Plan: Editor Rebuild (Again) to Fully Utilize CodeMirror

## 1. Goal

The current editor architecture has the Swift↔JS boundary in the wrong place. Swift reaches into the editor to manage things that properly belong to the editor: colors, fonts, scroll state, content dirty tracking. The result is inability to cleanly use CodeMirror's own extension system to its full advantage.

Pass 5 moves the boundary. Swift owns the app shell, file I/O, OS integration, and user settings persistence. The JS layer owns everything about the editing experience. The bridge becomes a thin, principled interface between those two concerns.

This pass covers currently-implemented features only. Search, heading collapse, tabs, and git diff are explicitly out of scope but the architecture should make them straightforward to add.

## 2. The new bridge interface

The bridge narrows to a small set of well-defined calls in each direction.

### 2.1. Swift → JS

All calls go through a single `window.editorBridge` object.

`load(payload)` is called once, in response to `editorReady`. The payload is a single object containing the document content, the saved scroll position, and the full current config. This replaces the current sequence of `setContent`, `markClean`, `setFocusMode`, `applyFocusModeCustomizations`, and the post-load style calls.

`updateConfig(patch)` is called whenever a setting changes. The patch is a sparse object containing only the keys that changed — font size, font family, color theme, focus mode state, autoscroll mode, image width, focus mode customizations. The JS layer applies only what it receives.

`getContent()` returns the document as a string. Swift calls this when saving.

`close()` signals the editor to clean up. Used when the Swift layer needs to initiate a save-and-close, for example from a keyboard shortcut or window close event.

### 2.2. JS → Swift

`editorReady` fires once, after CodeMirror has initialized. Swift responds with `load`.

`documentChanged` fires when the user modifies the document. Swift uses this to drive the autosave debounce. Swift manages its own dirty flag internally and does not need the editor to track or reset it.

`scrollPositionChanged(scrollTop)` fires on a debounced scroll event, for session persistence.

`openURL(url)` fires on Cmd+click on a link, for Swift to hand off to `NSWorkspace`.

`closeRequested` fires when the user triggers close from within the editor (e.g. a toolbar close button).

## 3. JS layer

### 3.1. Compartments

Compartments are CodeMirror's mechanism for reconfiguring extensions at runtime without rebuilding the editor. Each setting that can change after load gets its own compartment. This replaces the current pattern of injecting CSS strings via `evaluateJavaScript`.

The compartments needed for the current feature set are:

- Theme compartment — holds an `EditorView.theme()` call built from the active color palette. Updated when the color theme changes.
- Font compartment — holds the CSS overrides for font family and size, as a theme extension. Updated when either font setting changes.
- Autoscroll compartment — holds the autoscroll mode value. Updated when the setting changes.
- Image width compartment — holds the image max-width CSS rule. Updated when the setting changes.
- Focus mode compartment — holds the body class toggle and any associated CSS. Updated when focus mode state changes.

When `updateConfig(patch)` is called, the JS layer inspects the patch keys, rebuilds only the affected compartments, and dispatches a single transaction with all the compartment effects at once.

### 3.2. Extensions

The full extension list for the rebuilt editor:

- `markdown({ extensions: [GFM, footnoteParserFix] })` — the footnote parser fix is a small custom Lezer extension correcting a misclassification in the GFM parser. When a sentence ends with `!` followed immediately by a footnote reference — e.g. `Hey there![^ref]` — the parser treats the `!` as the start of image syntax (`![alt](url)`) and tags it as `processingInstruction`, coloring it text-muted instead of body text. The fix teaches the parser that `![...]` without a trailing `(url)` is not image syntax, so `!` is left as plain text and `[^ref]` is correctly recognized as a `FootnoteReference` node.
- `syntaxHighlighting(highlightStyle)` — expanded to cover more token types cleanly.
- `headingLineDecorations` — kept as-is, attaches line classes for heading sizes and blockquote.
- `inlineMarkDecorations` — kept, with the corrected footnote regex. If the Lezer extension fully fixes the parse tree, this may simplify further.
- `history()` and keymaps — unchanged. `history()` is a CodeMirror extension that maintains an undo/redo stack for document changes, enabling `Cmd+Z` and `Cmd+Shift+Z`. `historyKeymap` provides the key bindings that wire those shortcuts to the history extension. `defaultKeymap` provides a standard set of editing bindings — `Backspace`, `Delete`, arrow navigation, `Enter` for new lines, `Tab`, and so on. Without these three, the editor would have no keyboard interaction beyond typing characters.
- `EditorView.lineWrapping` — unchanged.
- `EditorView.updateListener` — for `documentChanged` post and centered scroll trigger.
- `EditorView.domEventHandlers` — for Cmd+click URL handling.
- Theme, font, autoscroll, image width, and focus mode compartments from 3.1.

The extension list is designed so that future additions (search, fold, gutter) slot in as additional compartments or top-level extensions without touching existing ones.

### 3.3. State management

`suppressDocChanged` stays as a module-level boolean. It is set and cleared synchronously within `setContent` dispatches, so it does not need to live in the editor state.

The centered scroll function stays as a module-level function triggered via `requestAnimationFrame` from the update listener.

`autoScrollMode` moves from a module-level variable into its compartment. The autoscroll function reads from the compartment state rather than the module variable.

### 3.4. Focus mode

Focus mode remains CSS-class-based on `document.body`, since it controls layout and background properties that are naturally expressed in CSS. The `updateConfig` call for focus mode updates the body class and, if fullscreen customizations apply, dispatches the focus compartment with the current wallpaper URL, dimness, and blur values.

The wallpaper fetch-and-paint timing logic currently in `applyFocusModeCustomizations` — which gates the Swift fade-in callback on the wallpaper being painted — can stay in the JS layer and report back via a new `focusWallpaperReady` post message.

## 4. Swift layer changes

### 4.1. EditorBridge

Methods removed: `setFontSize`, `setFontFamily`, `applyEditorStyle`, `fontFamilyCSS`, `setImageHalfWidth`, `applyColors`, `setAutoScroll`, `markClean`, `setContent`, `setContentAndScrollTo`, `setContentAndScrollToTop`, `setFocusMode`.

Methods added: `load(content:scrollTop:config:)`, which assembles the full payload object and calls `window.editorBridge.load`; `updateConfig(_:)`, which takes a dictionary and calls `window.editorBridge.updateConfig`.

Methods kept: `getContent(completion:)`, `selectAll()`, `setFocusWallpaper(dataURL:)`, `applyFocusModeCustomizations(enabled:onReady:)` — though the latter two may simplify once focus mode moves further into the JS layer.

The `isDirty` published property stays on the Swift side, set by `documentChanged` messages and reset internally after a save. It no longer needs to be synced back to JS.

### 4.2. WebViewAdapter (formerly WebEditorView)

The Coordinator class simplifies significantly. Its current job is tracking which settings have changed between `updateNSView` calls and firing bridge methods accordingly. With settings going through `updateConfig` from `EditView`'s `onChange` handlers instead, the Coordinator only needs to handle the initial page load (`webView(_:didFinish:)`), which calls `bridge.load` with the current config and content. The `lastScrollMode`, `lastFontSize`, `lastFontFamily`, and `lastImageHalfWidth` tracking fields are removed.

`makeNSView` stays mostly the same: WKWebViewConfiguration setup, color variable injection at document start, message handler registration, wallpaper scheme handler.

### 4.3. EditorMonitor (formerly EditView)

The `onReceive(bridge.$isReady)` handler simplifies to a single `bridge.load(...)` call assembling content and current settings.

The `onChange` handlers for `fontSize`, `fontFamily`, `appColors.surface`, and `isFocusMode` each become a one-line `bridge.updateConfig(...)` call.

`performSave` no longer calls `bridge.markClean()`. It resets `bridge.isDirty` directly on the Swift side by clearing the flag after a successful save.

The keyboard monitor in `onAppear` stays as-is; app-level shortcuts (Escape, Cmd+M, Cmd+A) remain in Swift.

## 5. What stays the same

`ProjectStore` — file I/O, scroll position persistence, blob metadata. No changes.

The `blobtxt://` wallpaper URL scheme handler in `WebViewAdapter` — no changes.

The save status island UI in `EditorMonitor` — no changes.

The `WallpaperSchemeHandler` and `WeakMessageHandler` classes — no changes.

`editor.html` — no changes.

`style.css` — minor changes only to support compartment-driven theming if any rules move from Swift-injected CSS into the stylesheet.
