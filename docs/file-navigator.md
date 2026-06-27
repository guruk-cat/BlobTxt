# File Navigator

## 1. Purpose

This document is a map of the file navigator, not a manual: it points to where things live, and the code carries the detailed explanations in comments. 

The file navigator is the sidebar — it shows a project's folders and files as a tree, and annotates rows with git file status (always on; nothing shows when the project isn't a git repo).

## 2. Where the panel lives

The sidebar is the navigator; there is no panel switcher.

- `Views/Sidebar/SidebarView.swift` is the sliding chrome (animation, width, surface) around `FileNavigatorView`.
- `App/BlobTxtApp.swift` defines the menu commands and the notification names. The `Toggle Navigator` command (Cmd+E) originates here; there is no on-screen toggle button. `SidebarView` observes `.toggleNavigator`.

## 3. The two halves of navigator state

State is split between a model that survives the panel closing and a view that holds transient UI state.

### 3.1. NavigatorModel

`Views/Sidebar/NavigatorModel.swift` owns the tree itself: the parsed directory nodes, which folders are expanded, the context directory for new-item creation, and the FSEvents watcher that keeps the tree in sync with on-disk changes. It also exposes `reloadCount`, bumped on every reload, which the view observes to re-run status after any change (including external `git add` writes, since the watcher sees `.git/` too).

`FileNode` (defined in the same file) is one node in the tree: a folder or a file. The navigator lists every file except dotfiles, keeping full filenames with their extensions rather than just `.md` blobs. `Models/FileKind.swift` adds the `URL.isBlobFile`/`isImageFile` helpers that classify a node by extension.

### 3.2. FileNavigatorView

The panel UI and behavior is split across three files in `Views/Sidebar/`:

`FileNavigatorView.swift` is the root struct and the home of shared types. It owns the drag-and-drop state and handlers, the rename and delete handlers, the header, and the `confirmationDialog`. It also defines the shared infrastructure used across the other two files: `navCoordinateSpace`, `RowFrameKey`, `sameFile`, `isWithin`, `RowIndicator`, and `RowBadge`.

`NodeRowsView.swift` is the recursive renderer for a list of sibling nodes. It computes each row's trailing indicator and recurses into expanded folders.

`FileRowView.swift` is a single row: leading symbol, name (or inline rename field), trailing indicator, background tinting, context menu, and the manual drag gesture. `HeaderIconButton`, the small icon button used in the header, lives here too.

Opening a row branches by file type: a blob opens in the editor, an image in the native `ImageViewer` (`Views/Editor/ImageViewer.swift`), and any other type is handed to the OS. Rename edits the whole filename including the extension.

## 4. ProjectStore and the `.blobtxt` marker

`Services/ProjectStore.swift` is the app's file-I/O layer. The navigator delegates all disk work to it: opening a project and file and folder CRUD (create, rename, move, delete; `renameFile` renames any file type, not only blobs). It is also the single source of truth for per-project state that must outlive the sidebar.

The `.blobtxt` marker is a per-project metadata file in YAML-like shape, parsed by hand (no YAML library). It currently holds just `name`. The `Marker` struct plus `readMarker`/`writeMarker` model it so a caller can touch one entry without disturbing the rest; to add a new persisted field, extend those.

## 5. Git status

`Services/GitTracker.swift` runs `git status --porcelain` off the main thread and exposes per-file badges plus a folder aggregate. Letters are colored by staging state. It is always on; `FileNavigatorView.refreshTracking()` calls it on project change and tree reloads. A non-repo project simply yields no badges.

Row indicators are funneled through one `RowIndicator` type (a list of letter badges for a file, or a dot for a folder), so `FileRowView` draws them uniformly. To change how a status looks, look at `indicator(for:)` in `NodeRowsView` and `trackingIndicator` in `FileRowView`.

## 6. Colors

The navigator's status colors are dedicated keys in `colors.json`, not reused from elsewhere: `git_untracked`/`git_unstaged`/`git_staged`. To retune a status color, edit both palettes. See `colors.md` for the palette system.

## 7. Common starting points

- Change what a row shows on the right: `indicator(for:)` (`NodeRowsView`) and `trackingIndicator` (`FileRowView`).
- Add or change a row's context-menu action: the `contextMenu` in `FileRowView`, wired through `NodeRowsView` to handlers in `FileNavigatorView`.
- Persist a new per-project setting: the `Marker` model and `readMarker`/`writeMarker` in `ProjectStore`.
- Change drag-and-drop behavior: the drag handlers in `FileNavigatorView`, the gesture in `FileRowView`.
- Touch git status logic: `GitTracker.swift`; nothing else spawns that tool.
