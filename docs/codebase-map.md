# BlobTxt Codebase Map

## 1. Purpose

This is the high-level mental model of the codebase: what each file does, where each feature lives, what is custom-built on CodeMirror 6, and the non-obvious decisions that shape the code. 

## 2. The Swift side

### 2.1. App shell

`App/BlobTxtApp.swift`: the main `WindowGroup`, the value-based `WindowGroup` that instances the mini views, the `Window` scene for the palette tool, all menu commands, and the `Notification.Name` definitions. Most cross-cutting actions are fired as notifications here and observed elsewhere. It also intercepts Cmd+E, Cmd+F, and Cmd+S at the app level, because the focused web view or a synthesized menu item would otherwise consume them before the SwiftUI menu shortcut fires; Cmd+E is swallowed when a mini view is the key window, since the navigator it toggles lives only in the main window. The font-size commands post step notifications rather than mutating storage directly, so the focused window applies them (see §6).

`Views/ContentView.swift`: the root layout (sidebar + editor region + floating island) and the app's state hub. It owns the active document URL, full-screen restore, and the settings sheet. `requestOpen` is the single entry point for switching documents — it flushes the current editor to disk before swapping. It also coordinates the mini views: opening a window for a blob, routing a mini-view link back into this window, and closing every mini window on a project change (§4).

`Views/MiniView.swift`: the editor-only window, one per blob, instanced by the blob URL the `WindowGroup` carries. It hosts an `EditorMonitor` filling the window, seeds its blob from the scene value, repoints in place when that blob is renamed or moved, and closes itself when the blob is deleted or its project changes. `Views/WindowAccessor.swift` is the small `NSViewRepresentable` it and `ContentView` use to reach their hosting `NSWindow` (window identity, key-window checks, closing).

`Views/FloatingIslandView.swift`: the hovering pill at bottom-left that toggles the sidebar and switches panels. It posts the toggle notifications the sidebar listens for. The navigator, file-operations, and metadata panels are implemented; one button still targets a placeholder.

### 2.2. Editor region

`Views/Editor/WebViewAdapter.swift`: the `NSViewRepresentable` that creates and configures the one `WKWebView`. It injects the active palette as CSS variables at document-start (avoiding a color flash), wires the message handler through a weak wrapper, and loads `editor.html`. It applies no settings itself.

`Views/Editor/EditorBridge.swift`: the typed boundary object. JS→Swift messages are handled in `userContentController`; Swift→JS calls are thin wrappers over `evaluateJavaScript`. Also resolves followed local links.

`Views/Editor/EditorMonitor.swift`: the SwiftUI view that hosts the web view and orchestrates one document's lifecycle — initial load on `editorReady`, debounced autosave, the save-status island, the Escape/Cmd+A key monitor, and pushing every settings change through `bridge.updateConfig`. It registers an `EditorFlush` handle so the owner can save before switching files. Its key monitor takes an `isModalOverlayActive` closure and yields while a file-ops overlay floats above (see §6). It acquires its blob's `BlobContent` from `LifecycleStore` on mount, loads from it, and saves through it; on every successful save it reconciles any same-blob surface (see §6). The same view backs both windows: an `isMini` flag selects the independent `miniFontSize`, and a `closesOnEscape` flag lets the mini view ignore Escape-to-close. Interactive shortcuts are gated on this editor's own key window so only the focused one acts (§6).

`Views/Editor/ImageViewer.swift`: a plain native `NSImage` viewer used when an image file is opened, so the app needs no second JS environment.

### 2.3. Sidebar (file navigator)

`Views/Sidebar/SidebarView.swift`: hosts the sidebar panels, owns the slide animation and width, and renders the active panel (navigator, file operations, or metadata). One panel is still a placeholder.

`Views/Sidebar/NavigatorModel.swift`: the navigator's tree state that survives the panel closing — the parsed `FileNode` tree, expanded folders, the creation-context directory, and the FSEvents watcher. `reloadCount` is bumped on every reload so the view can re-run status. Lives at the `ContentView` level.

`Views/Sidebar/FileNavigatorView.swift`: the panel UI and most navigator behavior — the recursive row renderer, the row view, the manual drag-and-drop, tracking-mode reordering, and the open/rename/delete/move handlers. The largest single file; see `file-navigator.md`.

### 2.4. Settings

`Views/Settings/SettingsView.swift`: the preferences sheet (font, the mini view's independent font size, editor behavior, color palette / system-appearance following, and the go-to print profile).

### 2.5. Services

`Services/ProjectStore.swift`: the source of truth for per-project persisted state. Handles project opening, blob/folder CRUD, and the hand-parsed `.blobtxt` marker file. It holds `activeContent` (the `BlobContent` open in the main editor, which the Metadata panel binds to). Blob content I/O itself now lives in `BlobContent` / `LifecycleStore`.

`Services/LifecycleStore.swift`: the registry of open blobs. Each editor surface acquires a `BlobContent` — the live in-memory owner of one blob's body and metadata, in `Models/` — keyed by symlink-resolved path, and releases it on unmount; the store reference-counts holders and flushes-then-evicts when the last one releases. It also holds the session scroll cache. `BlobContent` is the single writer for its blob (`save()` serializes the front matter ahead of the body) and the home of the front-matter format helpers.

`Services/BlobRepoint.swift`: the `BlobMoveInfo` payload and the pure helpers that compute where a blob lands after a move (direct match or folder rebase) or whether it sits under a deletion. The navigator broadcasts a move or deletion and each surface applies these to its own blob, so a rename or delete reaches every mini window without a single shared URL to mutate.

`Services/AppColors.swift`: loads `colors.json`, exposes the active palette as SwiftUI `Color`s, and serializes it for the editor (both as the document-start CSS injection and the `updateConfig` color dict).

`Services/FileSystemWatcher.swift`: a thin FSEvents wrapper that fires `onChange` (coalesced) when the project tree changes on disk, including external `.git/` writes.

`Services/GitTracker.swift`: runs `git status --porcelain` off the main thread and exposes per-file badges plus a folder aggregate for git mode.

`Services/PrintService.swift`: renders the open blob to PDF by shelling out to `pandoc --pdf-engine=weasyprint`, off the main thread. Takes a `LayoutProfile`, whose generated CSS it injects as the `--include-in-header` style (and passes `lang=en` when that profile enables hyphenation). File → Print fires `.printDocument`; `ContentView` flushes the editor, prompts for a destination with an `NSSavePanel`, then calls this with the go-to profile.

`Services/LayoutProfile.swift`: the page-layout profile model. Every styling field is optional — nil means "emit no CSS, let pandoc/weasyprint decide." Generates the `<style>` header block: `@page` size/orientation/margins/page-numbers and a `body` rule for font/size/alignment/hyphenation, plus always-on figure-caption numbering.

`Services/LayoutStore.swift`: the app-global source of truth for layout profiles plus the go-to reference (the profile File → Print uses). A shared singleton (`LayoutStore.shared`) that persists custom profiles to `~/Library/Application Support/BlobTxt/print.json`; the built-in default profile is synthesized in code and never written. Names are de-duplicated on add/duplicate/rename.

### 2.6. File operations

`Views/Sidebar/FileOpsPanelView.swift`: the File Operations sidebar panel, a set of route buttons into file-level services (Merge Blobs and Page Layout, both wired to their window-level panels via notifications). `Views/Sidebar/MetadataPanelView.swift`: the Metadata panel, editing the open blob's YAML front matter; it binds to `store.activeContent`.

The Merge Blobs wizard lives under `Views/FileOps/`: `MergeBlobsPanel` (the staged overlay shell and file write), the three stage views (`MergeSelectionStage`, `MergeHeadingsStage`, `MergeMetadataStage`), `MergeSession` (shared flow state), and `MergeEngine` (the merge transform, including the footnote renumbering ported from the editor). See `merge-blobs.md`.

The Page Layout panel also lives under `Views/FileOps/`: `PageLayoutPanel` (the 640×640 overlay shell — same chrome as Merge Blobs — with the left profile list and the Exit / buffered Save-Cancel footer) and `LayoutDetailPane` (the right-column editing form). It manages `LayoutStore`'s profiles: left-click or the row context menu edits a custom profile, with add / duplicate / remove / set-go-to; the default profile is read-only and only offers set-go-to. Launched from `FileOpsPanelView`, hosted as an overlay by `ContentView`.

## 3. The JS side

The editor JS lives under `editor-src/src/`, split across focused modules that `main.js` imports and assembles, plus `style.css` for the page skeleton. There is exactly one `EditorView` (a CodeMirror 6 thing), constructed in `main.js`, and every feature is an extension appended to its single `extensions` array (`cm-editor-customs.md` §2). `main.js` owns that construction, the config flow, and the `window.editorBridge` Swift calls; the other modules export the parts that feed it (theme, highlighting, parser fixes, decorations, the word-count gutter, footnotes, links, the search panel).

`js-map.md` is the map of this layer: the per-module breakdown, the cross-module seams, and the decisions behind the split. `cm-editor-customs.md` remains the deeper CM6 reference.

## 4. Where the features live

Editing surface, syntax colors, decorations: `editorBaseTheme` (`theme.js`), `highlightStyle` (`highlight.js`), the `ViewPlugin`s (`decorations.js`).

Find/replace: `createSearchPanel` in `search-panel.js` (custom DOM over CM6's search state), assembled and toggled from `main.js`; toggled from Swift via Cmd+F → `toggleSearch`.

Footnotes: parsing utilities and the hover tooltip in `footnotes.js`; the `arrangeFootnotes` rewrite command is a bridge method in `main.js`; the menu item is in `BlobTxtApp.swift`. Merge Blobs renumbers footnotes across blobs with a Swift port of `arrangeFootnotes` in `MergeEngine`; keep the two in sync.

Merge Blobs: launched from `FileOpsPanelView`, hosted by `ContentView`, implemented under `Views/FileOps/` with the transform in `MergeEngine`. See `merge-blobs.md`.

Printing and Page Layout: File → Print (`.printDocument`) renders the open blob to PDF with the go-to profile via `PrintService`. Layout profiles are edited in the Page Layout panel (launched from `FileOpsPanelView`, hosted by `ContentView`) and the go-to is also selectable in `SettingsView`; all of these read and write the one `LayoutStore.shared`, which generates the export CSS through `LayoutProfile`.

Mini view (open a blob in a dedicated editor-only window): launched from the navigator row's context menu, which posts `.openMiniView`; `ContentView` calls `openWindow` with the blob URL, opening a window for that blob or focusing the existing one (SwiftUI dedups by value). Several mini views can be open at once, one per blob, alongside the main editor; all surfaces on a blob bind to one `BlobContent`, and a save in any reconciles the rest (§6). The navigator broadcasts a rename, move, or deletion (`.blobMoved` / `.blobDeleted`) and each window repoints in place or closes accordingly; a project change posts `.closeAllMiniViews`. A mini view is identical to the main editor except for its own font size and a smaller, non-restored window. Cross-file links followed inside it route back to the main window via `.openInMain`.

Links (Cmd+click, in-doc anchors, cross-blob open): `openLink`/`goToHeading` in `links.js`, routed to Swift via `openURL`/`openBlob`, handled in `EditorBridge` and `ContentView`.

Save: debounced in `EditorMonitor`, which commits the editor's text to the blob's `BlobContent`; `BlobContent.save()` is the single writer; flushed before file switches via `EditorFlush`.

Scroll position per blob: posted from JS, cached in `LifecycleStore`, restored on load.

Word-count milestone gutter: `wordMilestones` state field and `wordCountGutter` in `gutters.js`.

## 5. Custom work built on CodeMirror 6

CM6 is used close to stock for the document model, history, search state machine, and markdown language. The custom layer, spread across the JS modules (`js-map.md`):

- Parser-level fixes for three markdown shapes CM6 mis-tags (`![^x]`, bare `[x]`, one-word footnote defs) and a fold restriction to heading sections.
- A re-tagging trick (`conspicuousMark`) so marks sharing one parser tag can take two different colors.
- Whole-line and sub-token decorations for things the parser has no node for (footnote refs and defs, link ranges).
- A custom search panel; the footnote hover tooltip is a stock `hoverTooltip()` over one source function.
- Two gutters: the heading-fold gutter and a word-count gutter that marks every hundredth word, fed by a `StateField` recomputed only on edits.
- The drawn caret/selection.

`file-navigator.md` covers the navigator's parallel custom work: a manual drag gesture instead of SwiftUI's `onDrag`, and per-mode row indicators funneled through one type.

## 6. Non-obvious decisions worth remembering

`.cm-scroller`, CM6's native scroll element, is the scroll container; `#editor` is a plain `overflow: hidden` wrapper. This native arrangement must be preserved, and a few behaviors drive `view.scrollDOM` directly — see `cm-editor-customs.md` §1.3 for why and which.

The scroller spans the full editor width; the centered text column is `.cm-content` (max-width + auto margins). The gutters are positioned out of flow in the left margin so the text stays centered regardless of gutter-number width — see `cm-editor-customs.md` §9.

Theming overrides CM6 by matching base-selector specificity and winning on mount order — never `!important`, and never `&light`/`&dark` inside `EditorView.theme()` (it throws). 

Settings never recreate the editor. They travel as a sparse config patch and are applied either by reconfiguring a `Compartment` or by touching the DOM/CSS directly. 

The Swift↔JS boundary is intentionally narrow: a new feature adds at most one bridge method and/or one message type, not a new transport.

Cross-component actions go through `NotificationCenter` (menu commands, panel toggles), so views stay decoupled from the menu and from each other.

App-wide shortcut notifications reach both windows, so window-scoped actions (search, arrange footnotes, font size, print, Escape, Cmd+A) are gated on the receiver's own key window; only the quit-time save is left ungated so it flushes both editors. Each editor finds its window through `bridge.webView.window` (live, so it works inside the long-lived key monitor); `ContentView` and `MiniView` use `WindowAccessor` for the same purpose.

Mini views are one window per blob, so they are a value-based `WindowGroup(for: URL.self)`: `openWindow` carries the blob URL and focuses an existing window for that blob rather than duplicating it. Each window owns its blob through the scene value instead of a shared store property, the value is never persisted, and the windows are marked non-restorable, keeping them scoped to a single app launch. Because there is no single shared URL to mutate, the navigator broadcasts a blob move or deletion and each window applies it to its own blob; a project change posts `.closeAllMiniViews`. Going value-based makes SwiftUI synthesize a disabled Save item that captures Cmd+S, so Cmd+S is intercepted in `AppDelegate` alongside Cmd+E and Cmd+F (see §2.1).

Each open blob has one in-memory owner, a `BlobContent` held in `LifecycleStore` and keyed by resolved path, that both surfaces bind to; it is the single writer to disk. Surfaces stay "safe, not live": a surface commits to the owner on save (debounce, blur, file switch, close, quit), and on each successful write a `.blobContentDidSave` notification makes any other surface on that blob reconcile to the saved content when it has no uncommitted edits — keeping the two consistent at save boundaries without syncing keystroke-by-keystroke. Divergent uncommitted edits resolve last-writer-wins. The owner is reference-counted and flushed-then-evicted when its last surface closes.

File identity is by symlink-resolved path, not URL equality, throughout the navigator. `contentsOfDirectory` returns URLs with trailing slashes and resolved symlinks, so raw `==` is unreliable (`sameFile`/`isWithin` exist for this).

Tracking status is computed off the main thread and only for the active mode, so an unused mode never spawns a subprocess. The FSEvents watcher catches external `git` writes and triggers a refresh.

The file-ops overlays (Merge Blobs, Page Layout) float over the still-open sidebar: opening one does not close the sidebar, the dimming scrim just covers it, so dismissing only removes the overlay. Escape cancels whichever overlay is up. The animation-transaction bug behind not closing/reopening the sidebar, and the Escape-yielding mechanism, are in the `ContentView` comments (`dismissFileOpsOverlay`) and `EditorMonitor`.
