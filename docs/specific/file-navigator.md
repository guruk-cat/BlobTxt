# File Navigator

## 1. Purpose

This document is a map of the file navigator, not a manual: it points to where things live, and the code carries the detailed explanations in comments. 

The file navigator is the sidebar panel that shows a project's folders and files as a tree. It has two "tracking modes" that annotate rows with file status: a plain mode and a git mode.

## 2. Where the panel lives

The navigator is one of the sidebar's panels.

- `Views/Sidebar/SidebarView.swift` hosts the panels and renders `FileNavigatorView` when the navigator panel is active. It owns the slide-in/out animation and the panel width.
- `Views/FloatingIslandView.swift` is the hovering island that toggles the sidebar open/closed and switches panels. It posts the notifications the sidebar listens for.
- `App/BlobTxtApp.swift` defines the menu commands and the notification names. The `Toggle Navigator` command originates here.

## 3. The two halves of navigator state

State is split between a model that survives the panel closing and a view that holds transient UI state.

### 3.1. NavigatorModel

`Views/Sidebar/NavigatorModel.swift` owns the tree itself: the parsed directory nodes, which folders are expanded, the context directory for new-item creation, and the FSEvents watcher that keeps the tree in sync with on-disk changes. It also exposes `reloadCount`, bumped on every reload, which the view observes to re-run status after any change (including external `git add` writes, since the watcher sees `.git/` too).

`FileNode` (defined in the same file) is one node in the tree: a folder or a file. The navigator lists every file except dotfiles, keeping full filenames with their extensions rather than just `.md` blobs. `Models/FileKind.swift` adds the `URL.isBlobFile`/`isImageFile` helpers that classify a node by extension.

### 3.2. FileNavigatorView

`Views/Sidebar/FileNavigatorView.swift` is the panel UI and most of the navigator's behavior. It contains several pieces worth knowing apart:

- The header (project name plus new-folder/new-blob buttons) and the bottom mode toggle.
- `NodeRowsView`, the recursive renderer for a list of sibling nodes. It computes each row's trailing indicator.
- `FileRowView`, a single row: leading symbol, name (or inline rename field), trailing indicator, background tinting, context menu, and the manual drag gesture.
- The drag-and-drop machinery (a manual `DragGesture` plus a hand-drawn overlay, not SwiftUI's `onDrag`).
- The handlers for open, rename, delete, and move. Opening a row branches by file type: a blob opens in the editor, an image in the native `ImageViewer` (`Views/Editor/ImageViewer.swift`), and any other type is handed to the OS. Rename edits the whole filename including the extension.

The mode itself is not stored here; the toggle reads and writes `store.trackingMode` so the choice persists (see section 5).

## 4. ProjectStore and the `.blobtxt` marker

`Services/ProjectStore.swift` is the app's file-I/O layer. The navigator delegates all disk work to it: opening a project, file and folder CRUD (create, rename, move, delete; `renameFile` renames any file type, not only blobs), and reading blob content. It is also the single source of truth for per-project state that must outlive the panel.

The `.blobtxt` marker is a per-project metadata file in YAML-like shape, parsed by hand (no YAML library). The `Marker` struct plus `readMarker`/`writeMarker` model it so a caller can touch one entry without disturbing the rest; to add a new persisted field, extend those.

## 5. The two tracking modes

`Models/TrackingMode.swift` defines the `regular`/`git` enum. Its raw values are the on-disk serialization in `.blobtxt`, so they must stay stable.

The active mode lives on `ProjectStore.trackingMode` (persisted to `.blobtxt`), not on the view, so it survives the sidebar closing and the app relaunching. `FileNavigatorView.refreshTracking()` refreshes only the active mode's status provider, so an unused mode never spawns a subprocess.

Git's row indicators are funneled through one `RowIndicator` type (a list of letter badges for a file, or a dot for a folder), so `FileRowView` draws them without per-mode branches. To change how a status looks, look at `indicator(for:)` in `NodeRowsView` and `trackingIndicator` in `FileRowView`.

### 5.1. Git mode

`Services/GitTracker.swift` runs `git status --porcelain` off the main thread and exposes per-file badges plus a folder aggregate. Letters are colored by staging state.

## 6. Colors

The navigator's status colors are dedicated keys in `colors.json`, not reused from elsewhere: `git_untracked`/`git_unstaged`/`git_staged`. To retune a status color, edit both palettes. See `colors.md` for the palette system.

## 7. Common starting points

- Change what a row shows on the right: `indicator(for:)` (`NodeRowsView`) and `trackingIndicator` (`FileRowView`).
- Add or change a row's context-menu action: the `contextMenu` in `FileRowView`, wired through `NodeRowsView` to handlers in `FileNavigatorView`.
- Persist a new per-project setting: the `Marker` model and `readMarker`/`writeMarker` in `ProjectStore`.
- Change drag-and-drop behavior: the drag handlers in `FileNavigatorView`.
- Touch git status logic: `GitTracker.swift`; nothing else spawns that tool.
