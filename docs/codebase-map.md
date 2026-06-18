# BlobTxt Codebase Map

## 1. Purpose

This is the high-level mental model of the codebase: what each file does, where each feature lives, what is custom-built on CodeMirror 6, and the non-obvious decisions that shape the code. 

## 2. The Swift side

### 2.1. App shell

`App/BlobTxtApp.swift`: the `WindowGroup`, all menu commands, and the `Notification.Name` definitions. Most cross-cutting actions are fired as notifications here and observed elsewhere. It also intercepts Cmd+E and Cmd+F at the app level, because WebKit/AppKit would otherwise consume them before the SwiftUI menu shortcut fires.

`Views/ContentView.swift`: the root layout (sidebar + editor region + floating island) and the app's state hub. It owns the active document URL, full-screen restore, and the settings sheet. `requestOpen` is the single entry point for switching documents — it flushes the current editor to disk before swapping.

`Views/FloatingIslandView.swift`: the hovering pill at bottom-left that toggles the sidebar and switches panels. It posts the toggle notifications the sidebar listens for. The navigator, file-operations, and metadata panels are implemented; one button still targets a placeholder.

### 2.2. Editor region

`Views/Editor/WebViewAdapter.swift`: the `NSViewRepresentable` that creates and configures the one `WKWebView`. It injects the active palette as CSS variables at document-start (avoiding a color flash), wires the message handler through a weak wrapper, and loads `editor.html`. It applies no settings itself.

`Views/Editor/EditorBridge.swift`: the typed boundary object. JS→Swift messages are handled in `userContentController`; Swift→JS calls are thin wrappers over `evaluateJavaScript`. Also resolves followed local links.

`Views/Editor/EditorMonitor.swift`: the SwiftUI view that hosts the web view and orchestrates one document's lifecycle — initial load on `editorReady`, debounced autosave, the save-status island, the Escape/Cmd+A key monitor, and pushing every settings change through `bridge.updateConfig`. It registers an `EditorFlush` handle so the owner can save before switching files. Its key monitor takes an `isModalOverlayActive` closure and yields while a file-ops overlay floats above (see §6).

`Views/Editor/ImageViewer.swift`: a plain native `NSImage` viewer used when an image file is opened, so the app needs no second JS environment.

### 2.3. Sidebar (file navigator)

`Views/Sidebar/SidebarView.swift`: hosts the sidebar panels, owns the slide animation and width, and renders the active panel (navigator, file operations, or metadata). One panel is still a placeholder.

`Views/Sidebar/NavigatorModel.swift`: the navigator's tree state that survives the panel closing — the parsed `FileNode` tree, expanded folders, the creation-context directory, and the FSEvents watcher. `reloadCount` is bumped on every reload so the view can re-run status. Lives at the `ContentView` level.

`Views/Sidebar/FileNavigatorView.swift`: the panel UI and most navigator behavior — the recursive row renderer, the row view, the manual drag-and-drop, tracking-mode reordering, and the open/rename/delete/move handlers. The largest single file; see `file-navigator.md`.

### 2.4. Settings

`Views/Settings/SettingsView.swift`: the preferences sheet (font, editor behavior, color palette / system-appearance following, and the go-to print profile).

### 2.5. Services

`Services/ProjectStore.swift`: the file-I/O layer and the source of truth for per-project persisted state. Handles project opening, blob/folder CRUD, blob read/write (preserving any YAML front matter), and the hand-parsed `.blobtxt` marker file.

`Services/AppColors.swift`: loads `colors.json`, exposes the active palette as SwiftUI `Color`s, and serializes it for the editor (both as the document-start CSS injection and the `updateConfig` color dict).

`Services/FileSystemWatcher.swift`: a thin FSEvents wrapper that fires `onChange` (coalesced) when the project tree changes on disk, including external `.git/` writes.

`Services/GitTracker.swift`: runs `git status --porcelain` off the main thread and exposes per-file badges plus a folder aggregate for git mode.

`Services/PrintService.swift`: renders the open blob to PDF by shelling out to `pandoc --pdf-engine=weasyprint`, off the main thread. Takes a `LayoutProfile`, whose generated CSS it injects as the `--include-in-header` style (and passes `lang=en` when that profile enables hyphenation). File → Print fires `.printDocument`; `ContentView` flushes the editor, prompts for a destination with an `NSSavePanel`, then calls this with the go-to profile.

`Services/LayoutProfile.swift`: the page-layout profile model. Every styling field is optional — nil means "emit no CSS, let pandoc/weasyprint decide." Generates the `<style>` header block: `@page` size/orientation/margins/page-numbers and a `body` rule for font/size/alignment/hyphenation, plus always-on figure-caption numbering.

`Services/LayoutStore.swift`: the app-global source of truth for layout profiles plus the go-to reference (the profile File → Print uses). A shared singleton (`LayoutStore.shared`) that persists custom profiles to `~/Library/Application Support/BlobTxt/print.json`; the built-in default profile is synthesized in code and never written. Names are de-duplicated on add/duplicate/rename. Note `print.json` lives in Application Support, not bundled `Resources/`, because profiles are user-edited and the app bundle is read-only.

### 2.6. File operations

`Views/Sidebar/FileOpsPanelView.swift`: the File Operations sidebar panel, a set of route buttons into file-level services (Merge Blobs and Page Layout, both wired to their window-level panels via notifications). `Views/Sidebar/MetadataPanelView.swift`: the Metadata panel, editing the open blob's YAML front matter.

The Merge Blobs wizard lives under `Views/FileOps/`: `MergeBlobsPanel` (the staged overlay shell and file write), the three stage views (`MergeSelectionStage`, `MergeHeadingsStage`, `MergeMetadataStage`), `MergeSession` (shared flow state), and `MergeEngine` (the merge transform, including the footnote renumbering ported from the editor). See `merge-blobs.md`.

The Page Layout panel also lives under `Views/FileOps/`: `PageLayoutPanel` (the 640×640 overlay shell — same chrome as Merge Blobs — with the left profile list and the Exit / buffered Save-Cancel footer) and `LayoutDetailPane` (the right-column editing form). It manages `LayoutStore`'s profiles: left-click or the row context menu edits a custom profile, with add / duplicate / remove / set-go-to; the default profile is read-only and only offers set-go-to. Launched from `FileOpsPanelView`, hosted as an overlay by `ContentView`.

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
10. Scroll behaviors (centered autoscroll).
11. The `EditorView` construction and the scroll/resize observers.
12. The config-application helpers and the `window.editorBridge` methods Swift calls.

## 4. Where the features live

Editing surface, syntax colors, decorations: `main.js` (`editorBaseTheme`, `highlightStyle`, the `ViewPlugin`s).

Find/replace: `main.js` `createSearchPanel` (custom DOM over CM6's search state); toggled from Swift via Cmd+F → `toggleSearch`.

Footnotes: parsing utilities, hover tooltip, and the `arrangeFootnotes` rewrite command, all in `main.js`; the menu item is in `BlobTxtApp.swift`. Merge Blobs renumbers footnotes across blobs with a Swift port of `arrangeFootnotes` in `MergeEngine`; keep the two in sync.

Merge Blobs: launched from `FileOpsPanelView`, hosted by `ContentView`, implemented under `Views/FileOps/` with the transform in `MergeEngine`. See `merge-blobs.md`.

Printing and Page Layout: File → Print (`.printDocument`) renders the open blob to PDF with the go-to profile via `PrintService`. Layout profiles are edited in the Page Layout panel (launched from `FileOpsPanelView`, hosted by `ContentView`) and the go-to is also selectable in `SettingsView`; all of these read and write the one `LayoutStore.shared`, which generates the export CSS through `LayoutProfile`.

Links (Cmd+click, in-doc anchors, cross-blob open): `openLink`/`goToHeading` in `main.js`, routed to Swift via `openURL`/`openBlob`, handled in `EditorBridge` and `ContentView`.

Save: debounced in `EditorMonitor`; written by `ProjectStore.saveBlobContent`; flushed before file switches via `EditorFlush`.

Scroll position per blob: posted from JS, stored in `ProjectStore.blobScrollPositions`, restored on load.

Word-count milestone gutter: `wordMilestones` state field and `wordCountGutter` in `main.js`.

## 5. Custom work built on CodeMirror 6

CM6 is used close to stock for the document model, history, search state machine, and markdown language. The custom layer, all in `main.js`:

- Parser-level fixes for three markdown shapes CM6 mis-tags (`![^x]`, bare `[x]`, one-word footnote defs) and a fold restriction to heading sections.
- A re-tagging trick (`conspicuousMark`) so marks sharing one parser tag can take two different colors.
- Whole-line and sub-token decorations for things the parser has no node for (footnote refs and defs, link ranges).
- A custom search panel; the footnote hover tooltip is a stock `hoverTooltip()` over one source function.
- Two gutters: the heading-fold gutter and a word-count gutter that marks every hundredth word, fed by a `StateField` recomputed only on edits.
- The drawn caret/selection.

`file-navigator.md` covers the navigator's parallel custom work: a manual drag gesture instead of SwiftUI's `onDrag`, and per-mode row indicators funneled through one type.

## 6. Non-obvious decisions worth remembering

`.cm-scroller`, CM6's native scroll element, is the scroll container; `#editor` is a plain `overflow: hidden` wrapper. A few behaviors still drive it directly through `view.scrollDOM`: the per-blob scroll-position bridge, centered autoscroll, and the bottom-padding ResizeObserver. Do not make `#editor` scroll instead: CM6 detects a scroll container by `scrollHeight > clientHeight` regardless of `overflow`, so a non-scrolling `.cm-scroller` silently breaks selection-follow autoscroll and `scrollIntoView`. See `cm-editor-customs.md` §1.3.

The scroller spans the full editor width; the centered text column is `.cm-content` (max-width + auto margins). The gutters are positioned out of flow in the left margin so the text stays centered regardless of gutter-number width — see `cm-editor-customs.md` §9.

Theming overrides CM6 by matching base-selector specificity and winning on mount order — never `!important`, and never `&light`/`&dark` inside `EditorView.theme()` (it throws). 

Settings never recreate the editor. They travel as a sparse config patch and are applied either by reconfiguring a `Compartment` or by touching the DOM/CSS directly. 

The Swift↔JS boundary is intentionally narrow: a new feature adds at most one bridge method and/or one message type, not a new transport.

Cross-component actions go through `NotificationCenter` (menu commands, panel toggles), so views stay decoupled from the menu and from each other.

File identity is by symlink-resolved path, not URL equality, throughout the navigator. `contentsOfDirectory` returns URLs with trailing slashes and resolved symlinks, so raw `==` is unreliable (`sameFile`/`isWithin` exist for this).

Tracking status is computed off the main thread and only for the active mode, so an unused mode never spawns a subprocess. The FSEvents watcher catches external `git` writes and triggers a refresh.

The file-ops overlays (Merge Blobs, Page Layout) float over the still-open sidebar: opening one does not close the sidebar, the dimming scrim just covers it, so dismissing only removes the overlay and never runs a sidebar reopen. Closing on open and reopening on dismiss put the overlay's removal transition and the sidebar's insertion transition in one animation transaction, which intermittently left the reopened sidebar mounted but non-interactive. Escape cancels whichever overlay is up: each panel installs its own key monitor, and `EditorMonitor`/`ImageViewer` yield Escape (via `isModalOverlayActive`) while an overlay is present, because the overlays live in the main window and so are not excluded by the usual `isKeyWindow` gate.
