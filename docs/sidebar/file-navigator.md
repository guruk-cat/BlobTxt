# File Navigator

## 1. Purpose

This document is a map, not a manual. It points to where things live. The code itself carries the detailed explanations in comments.

The file navigator is the sidebar panel that shows a project's folders and blobs as a tree. It has three "tracking modes" that annotate rows with file status: a plain mode, a git mode, and a blaze mode.

## 2. Where the panel lives

The navigator is one of the sidebar's panels.

- `Views/Sidebar/SidebarView.swift` hosts the panels and renders `FileNavigatorView` when the navigator panel is active. It owns the slide-in/out animation and the panel width.
- `Views/FloatingIslandView.swift` is the hovering island that toggles the sidebar open/closed and switches panels. It posts the notifications the sidebar listens for.
- `App/BlobTxtApp.swift` defines the menu commands and the notification names. The `Toggle Navigator` command and the `Blaze Clean…` command both originate here.

## 3. The two halves of navigator state

State is split between a model that survives the panel closing and a view that holds transient UI state.

### 3.1. NavigatorModel

`Views/Sidebar/NavigatorModel.swift` owns the tree itself: the parsed directory nodes, which folders are expanded, the context directory for new-item creation, and the FSEvents watcher that keeps the tree in sync with on-disk changes. It also exposes `reloadCount`, bumped on every reload, which the view observes to re-run status after any change (including external `git add` or `blaze` writes, since the watcher sees `.git/` and `.blaze/` too).

`FileNode` (defined in the same file) is one node in the tree: a folder or a `.md` blob.

### 3.2. FileNavigatorView

`Views/Sidebar/FileNavigatorView.swift` is the panel UI and most of the navigator's behavior. It contains several pieces worth knowing apart:

- The header (project name plus new-folder/new-blob buttons) and the bottom mode toggle.
- `NodeRowsView`, the recursive renderer for a list of sibling nodes. It computes each row's trailing indicator and, in blaze mode, the row reordering.
- `FileRowView`, a single row: leading symbol, name (or inline rename field), trailing indicator, background tinting, context menu, and the manual drag gesture.
- The drag-and-drop machinery (a manual `DragGesture` plus a hand-drawn overlay, not SwiftUI's `onDrag`).
- The handlers for open, rename, delete, move, and the blaze write actions.

The mode itself is not stored here; the toggle reads and writes `store.trackingMode` so the choice persists (see section 5).

## 4. ProjectStore and the `.blobtxt` marker

`Services/ProjectStore.swift` is the app's file-I/O layer. The navigator delegates all disk work to it: opening a project, blob and folder CRUD (create, rename, move, delete), and reading blob content. It is also the single source of truth for per-project state that must outlive the panel.

The `.blobtxt` marker is a per-project metadata file in YAML-like shape, parsed by hand (no YAML library). It has two kinds of entries: top-level `key: value` scalars (`name`, `mode`) and indented sections (`mark_abbreviations`). The `Marker` struct plus `readMarker`/`writeMarker` model it so a caller can touch one entry without disturbing the rest. To add a new persisted field, extend those.

## 5. The three tracking modes

`Models/TrackingMode.swift` defines the `regular`/`git`/`blaze` enum. Its raw values are the on-disk serialization in `.blobtxt`, so they must stay stable.

The active mode lives on `ProjectStore.trackingMode` (persisted to `.blobtxt`), not on the view, so it survives the sidebar closing and the app relaunching. `FileNavigatorView.refreshTracking()` refreshes only the active mode's status provider, so an unused mode never spawns a subprocess.

Row indicators from both git and blaze are funneled through one `RowIndicator` type (a list of letter badges for a file, or a dot for a folder), so `FileRowView` draws them without per-mode branches. To change how a status looks, look at `indicator(for:)` in `NodeRowsView` and `trackingIndicator` in `FileRowView`.

### 5.1. Git mode

`Services/GitTracker.swift` runs `git status --porcelain` off the main thread and exposes per-file badges plus a folder aggregate. Letters are colored by staging state.

### 5.2. Blaze mode

`Services/BlazeTracker.swift` integrates the external `blaze` CLI (a file-development tracker; see `blaze.md`). The split is deliberate:

- Reads are direct: it parses `.blaze/marks.toml` for each file's mark, never shelling out to read.
- Writes shell out to the `blaze` binary at `~/.local/bin/blaze`, the only supported way to mutate blaze state. `applyMark`/`bumpUp`/`bumpDown` back the row context menu; `recordRename` reconciles a move or rename via blaze's manual `rename` form; `refreshHashes` re-hashes tracked files on app quit; `cleanPreview`/`clean` back the Blaze Clean dialog.

Two-letter abbreviations come from `.blobtxt`'s `mark_abbreviations` section, seeded with defaults the first time a blaze project is opened (in `ProjectStore.openProject`). Hierarchy marks are colored by saturation per level; flat marks get a separate color. Blaze mode also reorders blobs by mark; that comparator (`orderedNodes`/`blazeOrder`) is in `NodeRowsView`.

The Blaze Clean dialog is hosted in `Views/ContentView.swift`, triggered by the `File → Blaze Clean…` menu item via the `.blazeClean` notification.

## 6. Colors

`Resources/colors.json` holds the palettes. `Services/AppColors.swift` loads them and exposes the `Color` properties. The navigator's status colors are dedicated keys, not reused from elsewhere: `git_untracked`/`git_unstaged`/`git_staged` and `blaze_hierarchy`/`blaze_flat`. The per-level blaze saturation ramp is `AppColors.blazeHierarchyColor(fraction:)`. To retune a status color, edit both palettes in `colors.json`.

## 7. Common starting points

- Change what a row shows on the right: `indicator(for:)` (`NodeRowsView`) and `trackingIndicator` (`FileRowView`).
- Add or change a row's context-menu action: the `contextMenu` and `blazeMenu` in `FileRowView`, wired through `NodeRowsView` to handlers in `FileNavigatorView`.
- Persist a new per-project setting: the `Marker` model and `readMarker`/`writeMarker` in `ProjectStore`.
- Change drag-and-drop or reordering behavior: the drag handlers and `orderedNodes`/`blazeOrder` in `FileNavigatorView`.
- Touch git or blaze status logic: `GitTracker.swift` or `BlazeTracker.swift` respectively; nothing else spawns those tools.
