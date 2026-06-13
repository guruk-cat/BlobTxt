# BlobTxt Codebase Map

## 1. Purpose

This is the high-level mental model of the codebase: what each file does, where each feature lives, what is custom-built on CodeMirror 6, and the non-obvious decisions that shape the code. 

## 2. The Swift side

### 2.1. App shell

`App/BlobTxtApp.swift`: the `WindowGroup`, all menu commands, and the `Notification.Name` definitions. Most cross-cutting actions are fired as notifications here and observed elsewhere. It also intercepts Cmd+E and Cmd+F at the app level, because WebKit/AppKit would otherwise consume them before the SwiftUI menu shortcut fires.

`Views/ContentView.swift`: the root layout (sidebar + editor region + floating island) and the app's state hub. It owns the active document URL, focus-mode and full-screen state, the settings sheet, and app-wide dialogues (e.g., "blaze clean"). `requestOpen` is the single entry point for switching documents — it flushes the current editor to disk before swapping.

`Views/FloatingIslandView.swift`: the hovering pill at bottom-left that toggles the sidebar and switches panels. It posts the toggle notifications the sidebar listens for. Only the navigator panel is implemented; the other three island buttons target placeholder panels.

### 2.2. Editor region

`Views/Editor/WebViewAdapter.swift`: the `NSViewRepresentable` that creates and configures the one `WKWebView`. It injects the active palette as CSS variables at document-start (avoiding a color flash), wires the message handler through a weak wrapper, registers the `blobtxt://` wallpaper scheme, and loads `editor.html`. It applies no settings itself.

`Views/Editor/EditorBridge.swift`: the typed boundary object. JS→Swift messages are handled in `userContentController`; Swift→JS calls are thin wrappers over `evaluateJavaScript`. Also resolves followed local links and drives the focus-mode wallpaper.

`Views/Editor/EditorMonitor.swift`: the SwiftUI view that hosts the web view and orchestrates one document's lifecycle — initial load on `editorReady`, debounced autosave, the save-status island, the Escape/Cmd+M/Cmd+A key monitor, and pushing every settings change through `bridge.updateConfig`. It registers an `EditorFlush` handle so the owner can save before switching files.

`Views/Editor/ImageViewer.swift`: a plain native `NSImage` viewer used when an image file is opened, so the app needs no second JS environment.

### 2.3. Sidebar (file navigator)

`Views/Sidebar/SidebarView.swift`: hosts the sidebar panels, owns the slide animation and width, and renders the navigator when its panel is active. The other panels are placeholders.

`Views/Sidebar/NavigatorModel.swift`: the navigator's tree state that survives the panel closing — the parsed `FileNode` tree, expanded folders, the creation-context directory, and the FSEvents watcher. `reloadCount` is bumped on every reload so the view can re-run status. Lives at the `ContentView` level.

`Views/Sidebar/FileNavigatorView.swift`: the panel UI and most navigator behavior — the recursive row renderer, the row view, the manual drag-and-drop, tracking-mode reordering, and the open/rename/delete/move handlers. The largest single file; see `file-navigator.md`.

### 2.4. Settings

`Views/Settings/SettingsView.swift`: the preferences sheet (font, editor behavior, color palette / system-appearance following).

`Views/Settings/FocusCustomizationView.swift`: the focus-mode sub-panel (wallpaper, dimness, blur, floating window), reached from settings. Its values apply only in full screen.

### 2.5. Services

`Services/ProjectStore.swift`: the file-I/O layer and the source of truth for per-project persisted state. Handles project opening, blob/folder CRUD, blob read/write (preserving any YAML front matter), and the hand-parsed `.blobtxt` marker file.

`Services/AppColors.swift`: loads `colors.json`, exposes the active palette as SwiftUI `Color`s, and serializes it for the editor (both as the document-start CSS injection and the `updateConfig` color dict).

`Services/FileSystemWatcher.swift`: a thin FSEvents wrapper that fires `onChange` (coalesced) when the project tree changes on disk, including external `.git/` and `.blaze/` writes.

`Services/GitTracker.swift`: runs `git status --porcelain` off the main thread and exposes per-file badges plus a folder aggregate for git mode.

`Services/BlazeTracker.swift`: integrates the external `blaze` CLI for blaze mode. Reads parse `.blaze/marks.toml` directly; writes shell out to the `blaze` binary.

## 3. The JS side

All editor JS is one file, `editor-src/src/main.js`, plus `style.css` for the page skeleton. There is exactly one `EditorView` (a CodeMirror 6 thing), and every feature is an extension appended to its `extensions` array (`cm-editor-customs.md` §2). The flat structure of the file, top to bottom:

1. The Swift bridge `post()` helper and module-level state.
2. The font compartment (the only runtime-reconfigurable extension).
3. Four Lezer parser tweaks (footnote/bracket/definition fixes, heading-only fold).
4. `editorBaseTheme`: all static `.cm-*` styling.
5. Syntax highlighting + the conspicuous-mark re-tagging.
6. Three decoration `ViewPlugin`s (heading lines, footnote-ref spans, link ranges) and Cmd-key tracking.
7. Link navigation (slugs, anchor jumps, link routing).
8. Footnote parsing utilities + the hover tooltip.
9. The custom search panel.
10. Scroll behaviors (centered autoscroll, page scroll).
11. The `EditorView` construction and the scroll/resize observers.
12. The config-application helpers and the `window.editorBridge` methods Swift calls.

## 4. Where the features live

Editing surface, syntax colors, decorations: `main.js` (`editorBaseTheme`, `highlightStyle`, the `ViewPlugin`s).

Find/replace: `main.js` `createSearchPanel` (custom DOM over CM6's search state); toggled from Swift via Cmd+F → `toggleSearch`.

Footnotes: parsing utilities, hover tooltip, and the `arrangeFootnotes` rewrite command, all in `main.js`; the menu item is in `BlobTxtApp.swift`.

Links (Cmd+click, in-doc anchors, cross-blob open): `openLink`/`goToHeading` in `main.js`, routed to Swift via `openURL`/`openBlob`, handled in `EditorBridge` and `ContentView`.

Save: debounced in `EditorMonitor`; written by `ProjectStore.saveBlobContent`; flushed before file switches via `EditorFlush`.

Scroll position per blob: posted from JS, stored in `ProjectStore.blobScrollPositions`, restored on load.

Focus mode + wallpaper: state in `ContentView`, body classes/CSS in `main.js` + `style.css`, wallpaper served through the `blobtxt://` scheme in `WebViewAdapter`.

## 5. Custom work built on CodeMirror 6

CM6 is used close to stock for the document model, history, search state machine, and markdown language. The custom layer, all in `main.js`:

- Parser-level fixes for three markdown shapes CM6 mis-tags (`![^x]`, bare `[x]`, one-word footnote defs) and a fold restriction to heading sections.
- A re-tagging trick (`conspicuousMark`) so marks sharing one parser tag can take two different colors.
- Whole-line and sub-token decorations for things the parser has no node for (footnote refs and defs, link ranges).
- A custom search panel and a footnote hover tooltip that bypasses `hoverTooltip()` to keep `clip: false`.
- The drawn caret/selection and the focus-mode page chrome.

`file-navigator.md` covers the navigator's parallel custom work: a manual drag gesture instead of SwiftUI's `onDrag`, and per-mode row indicators funneled through one type.

## 6. Non-obvious decisions worth remembering

`#editor`, not `.cm-scroller`, is the real scroll container. This is what lets the focus-mode wallpaper sit behind a scrolling document and gives Swift one element whose `scrollTop` it saves per blob. It is also why several behaviors are hand-built: bottom-padding tracking, page scroll, centered autoscroll, the scroll-position bridge, and the footnote tooltip's `clip: false`. See `cm-editor-customs.md` §1.3.

Theming overrides CM6 by matching base-selector specificity and winning on mount order — never `!important`, and never `&light`/`&dark` inside `EditorView.theme()` (it throws). 

Settings never recreate the editor. They travel as a sparse config patch and are applied either by reconfiguring a `Compartment` or by touching the DOM/CSS directly. 

The Swift↔JS boundary is intentionally narrow: a new feature adds at most one bridge method and/or one message type, not a new transport.

Cross-component actions go through `NotificationCenter` (menu commands, panel toggles, focus mode), so views stay decoupled from the menu and from each other.

File identity is by symlink-resolved path, not URL equality, throughout the navigator. `contentsOfDirectory` returns URLs with trailing slashes and resolved symlinks, so raw `==` is unreliable (`sameFile`/`isWithin` exist for this).

Tracking status is computed off the main thread and only for the active mode, so an unused mode never spawns a subprocess. The FSEvents watcher catches external `git`/`blaze` writes and triggers a refresh.

`blaze` reads are direct file parses; only mutations shell out to the binary. Renames/moves are reported to blaze regardless of the active mode so a mark is never orphaned.
