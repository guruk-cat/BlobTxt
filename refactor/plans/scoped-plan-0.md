# Refactor Demolition Pass

## 1. Overview

This pass clears the deck before the refactor proper. Features that will be rebuilt from scratch after Phases 1–3 are removed now, eliminating backward-compatibility obligations from those phases. After this pass, the app can open a project directory and display a flat list of its blobs. Nothing more.

## 2. What Gets Retired

### 2.1. Sidebar Panels

`BlobOutlineView`, `BlobSearchView`, and `BlobMetadataView` are removed. The `SidebarPanel` enum retains all four cases, but the three non-navigator cases render a shared placeholder view that reads "This panel is not yet available." `FloatingIslandView` keeps all four buttons; the three non-navigator buttons are visible but disabled.

### 2.2. Output Features

**File → Export to Document** and print functionality are removed from the menu bar entirely. No disabled state or stub menu item is needed — the entries are just gone.

### 2.3. ProjectStore

The following are deleted from `ProjectStore.swift`:

- `loadBlobPlainText`
- `loadBlobHeadings`
- `loadBlobExcerpt`
- `loadBlobWordCount`
- `loadBlobHTML` and `renderNodeHTML`
- `replaceAllInBlobs` and `replaceInNode`
- `searchBlobs`
- `searchSnippets`
- `updateBlobMetadata`
- `exportBlobDocx`
- `activeEditorBlobID` (`@Published var`; its sole role was gating the now-retired export menu item)

### 2.4. Navigator Infrastructure

`CrossPanelDrag.swift` is deleted. `ItemFrameKey`, ghost placeholder logic, and all drag-reorder code are removed from `FileNavigatorView`. `NavigatorItem`, `ProjectStore.SearchResult`, and `ProjectStore.SnippetMatch` model types are deleted. `FileNavigatorView` itself is replaced with the minimal implementation described in section 3.

## 3. Bare-Minimum Navigator

The placeholder navigator has one job: show the blobs in the current project and open one when tapped. It is a fresh file, not a modification of the existing `FileNavigatorView`.

### 3.1. Content

The navigator shows a flat, recursive list of all `.md` files found anywhere in the project directory tree, sorted alphabetically by filename. Files not at the project root include the name of their immediate parent directory as secondary text, so files with the same name in different folders are distinguishable. Hidden files, `.blobtxt`, and non-`.md` items are filtered out. Subfolder hierarchy is not represented as an interactive tree — that comes with the full navigator rebuild.

### 3.2. Interactions

The implementer's job in this phase is to build the list display only. The tap-to-open wiring is deferred to Phase 1, where URL-based blob identity is established and `activeEditorURL: URL?` is introduced. There is no drag-and-drop, no context menus, and no folder expand/collapse.

### 3.3. Data Loading

The list is populated on appear and refreshed when the project changes. No `FSEventStream` watcher is set up at this stage — changes made outside the app are not reflected until the project is re-opened. This is a known limitation of the placeholder.
