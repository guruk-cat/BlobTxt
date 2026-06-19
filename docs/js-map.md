# BlobTxt JS Map

## 1. Purpose

This is the mental model of the editor's JavaScript layer: how it is split across files, what each module owns, and the architectural decisions that hold the split together. It is the JS counterpart to `codebase-map.md`, broken out so that map does not have to carry editor internals.

This document deliberately stops at the architecture. For how a specific feature renders or behaves, read the code and its comments; for the deeper CodeMirror 6 (CM6) reference — the theming model, the parser fixes, the decoration division of labor — see `cm-editor-customs.md`.

## 2. Architectural Decisions

These are the invariants every module is built around. They are the reason the split is safe.

### 2.1. One EditorView, one extension array

There is exactly one `EditorView` for the whole app, constructed once in `main.js` and held in the module-level `view` constant. Every feature is mounted by appending an extension to the single `extensions` array passed to that construction. Nothing recreates the view; anything that must change at runtime is wrapped in a `Compartment` and reconfigured instead. This is the load-bearing rule, covered in full in `cm-editor-customs.md` §2.

### 2.2. main.js is the assembly point; modules are the parts

`main.js` owns the singleton `view`, the `window.editorBridge` object Swift calls, the scroll/resize observers, and the config-application flow. The feature modules export the pieces that feed the extension array (themes, parser tweaks, decoration plugins, the gutter, the search panel) plus a few helpers `main.js` calls. A module never constructs or stores the `view`; functions that need it take it as a parameter, and the few that are bound to the singleton (the config helpers, the centered-scroll, the bridge methods) stay in `main.js`.

### 2.3. Shared mutable state lives in state.js

The cross-cutting mutable flags — the document-change suppression flag, the mirrored font size and family, and the autoscroll mode — live on the one `state` object in `state.js`. They are a single object rather than bare exported `let`s because ES module imports are read-only live bindings: an importer cannot reassign an imported value, but it can mutate a property. `state.js` also holds `post()`, the JS-to-Swift sender, so modules that report to Swift (for example `links.js`) can import it without pulling in `main.js` and forming a cycle. Keeping this module dependency-free is what keeps the import graph acyclic.

### 2.4. The Swift boundary stays narrow

Communication with Swift is two channels only: `post()` sends typed messages out, and `window.editorBridge` methods are called in. A new Swift-facing feature adds at most one message type and one bridge method, never a new transport. See `cm-editor-customs.md` §1.2.

## 3. The Modules

All under `editor-src/src/`, bundled by Vite into `BlobTxt/Resources/editor.html`. `style.css` remains the page skeleton only (no `.cm-*` styling).

| Module | Owns |
| --- | --- |
| `state.js` | `post()` and the shared mutable `state` object. Dependency-free. |
| `main.js` | The `EditorView` construction and its extension array, the observers, the config helpers, and `window.editorBridge`. |
| `theme.js` | `editorBaseTheme` (static `.cm-*` styling) and `buildFontTheme` (the runtime font/size/column-width theme). |
| `highlight.js` | The token `HighlightStyle` and the conspicuous-mark re-tagging. |
| `parser-extensions.js` | The three Lezer parser fixes and the heading-only fold restriction. |
| `decorations.js` | The heading-line, footnote-reference, and link `ViewPlugin`s, plus Cmd-key tracking. |
| `gutters.js` | The word-count milestone gutter and its backing `StateField`. |
| `footnotes.js` | Footnote parsing utilities, the hover tooltip, and the shared reference regex `fnRefRe`. |
| `links.js` | Slugs, in-document anchor jumps, and Cmd+click link routing. |
| `search-panel.js` | The custom find/replace panel DOM passed to `search({ createPanel })`. |

## 4. Cross-Module Seams

A few dependencies cross module lines on purpose; these are the ones worth knowing before editing.

`fnRefRe`, the inline footnote-reference regex, is defined once in `footnotes.js` and imported by both `decorations.js` (to mark reference spans) and `main.js` (for `arrangeFootnotes`). It is a `/g` regex, so every consumer resets `lastIndex` before iterating.

`arrangeFootnotes` is a bridge method, so it stays in `main.js`, but its parsing (`collectFootnoteDefs`, `fnRefRe`) comes from `footnotes.js`. The string-rewriting body is inline in the bridge method.

`goToHeading` is exported from `links.js` and has two callers: `openLink` uses it internally for a `#fragment`, and the `scrollToHeading` bridge method in `main.js` calls it after a cross-file link.

The `@codemirror/search` imports divide by role: `search-panel.js` imports the query commands and effects it drives (`findNext`, `replaceAll`, `setSearchQuery`, …), while `main.js` imports only what it needs to assemble and toggle the panel (`search`, `searchKeymap`, `openSearchPanel`, `closeSearchPanel`, `searchPanelOpen`).

`syntaxTree` is imported in `main.js` as well as `decorations.js`, because the Cmd+click handler in the view's `domEventHandlers` resolves the clicked position to a URL node.

## 5. Configuration Flow

Settings arrive from Swift as a sparse config patch through `load()` (once) and `updateConfig()` (per change), both in `main.js`. Each patch is split between `buildCompartmentEffects()`, which reconfigures the font `Compartment`, and `applyConfigToDOM()`, which sets the CSS color variables, the injected `::selection` style, the autoscroll mode, and the mini-view class. The font mirrors in `state` exist so a partial patch can still rebuild the combined font theme. The full rationale is in `cm-editor-customs.md` §10.
