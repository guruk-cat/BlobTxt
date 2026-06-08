# Dashboard

**The dashboard is NO LONGER IN USE. This documentation is only left as a legacy refernce in case I need it later.**

## UX Overview

The dashboard is the default view when no blob is open. It displays the contents of the selected project (or folder) as a card grid: folder cards and blob cards. Folders are smaller cards; blob cards show a title and a body preview with inline formatting preserved.

Users can create new folders and blobs via a floating button island in the bottom-right corner. Cards support context menus for rename, delete, copy, print, and move operations. Drag-and-drop reorders cards and allows dropping blobs into folders.

## Navigation State

Root state lives in `ContentView`:

- `selectedProjectID` — which project is active
- `selectedFolderID` — which folder (if any) is being viewed in the dashboard
- `activeBlobID` — which blob (if any) is open in the editor
- `isSidebarOpen` — sidebar visibility

The dashboard shows items for the selected context (project root or specific folder). The editor appears when `activeBlobID` is set.

## DashboardView (`Sources/Views/Dashboard/DashboardView.swift`)

`LazyVGrid` layout displaying folders (80pt cards) and blobs (200pt cards) with full drag-and-drop support.

**Drag state machine:**

- Ghost placeholders show target position
- Folder drag detection for moving blobs into folders
- ESC key cancels active drag
- Confirm glow animation on successful drop

**Floating island of buttons:**

- New folder button
- New blob button

**Context menus:**

- Rename/delete folders
- Copy/print/delete blobs
- Move blobs to root

## CardView (`Sources/Views/Dashboard/CardView.swift`)

Renders three types of cards:

**Folder cards** (80pt)

- Icon + name
- Click to navigate into folder
- Drop target for blob drags

**Blob cards** (200pt)

- Title (first heading from TipTap JSON)
- Body preview with inline formatting preserved (bold/italic/underline)
- Empty state indicator
- Hover-revealed copy button (copies both HTML and plain text)
- Async loads `BlobExcerpt` on mount via `store.loadBlobExcerpt`

**Ghost cards** (placeholder)

- Dashed border indicating drop position
