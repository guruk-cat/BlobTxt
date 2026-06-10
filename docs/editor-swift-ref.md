# Swift-Side Reference for Split View and Git Diffing

This document outlines what the Swift layer will need to do when we implement split-screen viewing and an in-editor git diff view. It is a planning note, not an implementation. The CodeMirror/JavaScript side is covered separately. Here, the focus is on the Swift architecture, because that is where the real coordination work lives.

The current editor stack is worth restating, since both features build on it:

- `ContentView` holds a single `activeEditorURL: URL?` and presents one `EditorMonitor`, keyed with `.id(url)` so SwiftUI rebuilds it when the open blob changes.
- Each `EditorMonitor` owns its own `EditorBridge` (`@StateObject`) and a single `WebViewAdapter`, which wraps one `WKWebView` loading `editor.html`.
- `EditorBridge` is the only Swift-to-JS channel: it sends `load(...)` and `updateConfig(...)` and receives messages (`editorReady`, `documentChanged`, etc.).
- Some behaviors are wired app-wide rather than per-editor: the `saveDocument`, `toggleSearch`, and `toggleFocusMode` notifications, plus the global `NSEvent` keyboard monitor that `EditorMonitor` installs for Escape, Cmd+M, and Cmd+A.

## 1. Split View
### 1.1. The core layout change

The minimal-friction approach is to run two independent editors. Because `EditorMonitor` already creates its own bridge and web view, a second `EditorMonitor` instance is fully isolated with no changes to that view itself. The work is in `ContentView`:

- Add a second slot, for example `secondaryEditorURL: URL?`.
- When it is non-nil, replace the single editor area with a horizontal split. AppKit's `HSplitView` gives a draggable divider for free; a custom `GeometryReader`-based splitter is the alternative if we want full control over the divider's look.
- Each pane is its own `EditorMonitor(url:...)`, each keyed with `.id(url)` as today.

This handles "two different blobs" cleanly. The "two portions of the same blob" case has a caveat covered in section 1.4.

### 1.2. Triggering the split

This needs a new notification and a menu item, following the exact pattern already used for `toggleNavigator` and `toggleSearch`:

- Add a notification name (e.g. `openInSplit` or `toggleSplitView`) in `BlobTxtApp.swift`.
- Add a menu command with a keyboard shortcut in the same `CommandGroup` block.
- The sidebar needs a way to choose which blob goes into the second pane. The natural options are a context-menu item ("Open in Split") on a blob row, or a modifier-click. `SidebarView` already receives `activeEditorURL` as a binding, so it would receive a second binding for the secondary URL.

### 1.3. Coordination hazards

This is the part that is easy to underestimate. Several things are currently global and assume a single editor:

- Escape, Cmd+A, Cmd+M: each `EditorMonitor` installs its own `NSEvent.addLocalMonitorForEvents` monitor. With two panes, both monitors fire for every keystroke, so both would try to handle Escape or select-all. We need a notion of the "focused pane" so only one responds. The cleanest fix is to track which pane holds first-responder status and have each monitor bail out when it is not the active one.
- `toggleSearch` (Cmd+F): posted app-wide, so both bridges would open their search panels at once. It must be routed to the focused pane only.
- `saveDocument`: both panes listening and each saving its own document is actually correct, so this one needs no change. The same is true of the terminate-time save.
- Scroll position: `store.blobScrollPositions` is keyed by `URL`. Two panes showing the same blob would write to the same key and clobber each other. If we support the same-blob case, the scroll key must become per-pane, not per-URL.

### 1.4. The same-blob case

With two isolated editors (the section 1.1 approach), opening the same blob in both panes gives two independent copies of the document. Edits in one pane do not appear in the other, and saving both creates a last-writer-wins conflict. That is fine for "compare two different blobs" but wrong for "view two portions of one live document."

True shared editing of one document is mostly a JavaScript-side change: one document state feeding two CodeMirror views that stay in sync. If we go that route, the Swift side changes shape. Instead of two `EditorMonitor` instances, there is one bridge and one web view hosting both panes, and the bridge protocol grows to address messages per pane (which view changed, which view to scroll, and so on). This is more work and more coupling, so it is worth deciding up front which of the two split behaviors we actually want before building either.

### 1.5. Interaction with focus mode

Focus mode assumes a single full-width editor and a fullscreen window. Split view and focus mode should be mutually exclusive: entering split should leave or disable focus mode, and the split menu item should be unavailable while in focus mode. `ContentView` already centralizes the `isFocusMode` state, so this is a guard there rather than new machinery.

## 2. Git Diff View

The JavaScript side has a ready-made tool here: `@codemirror/merge` provides a side-by-side merge view with change gutters. The hard part is entirely on the Swift side, and it is mostly about getting the "other" version of the file and doing so from inside a sandboxed app.

### 2.1. Producing the base version to diff against

A diff needs two inputs: the working copy (which the editor already has) and a base version (typically the file as it exists at git `HEAD`). The base text has to come from git, and the only realistic way to obtain it is to run git:

- Detect whether the open project's folder is a git repository.
- Resolve the blob's path relative to the repository root.
- Run something equivalent to `git show HEAD:<relative-path>` to read the committed version, capturing its output as a string.

This means shelling out with `Process` (or linking a git library). Both run into the sandbox.

### 2.2. The sandbox constraint

`BlobTxt.entitlements` sandboxes the app. A sandboxed app cannot freely launch `/usr/bin/git`, and even file reads outside user-granted scope are blocked. This is the single biggest Swift-side question for this feature, and it should be resolved before any UI work. The realistic options are:

- Confirm whether launching git is permitted under the current entitlements, and if not, whether a specific entitlement (or disabling the sandbox for this build) is acceptable for how the app is distributed.
- Use a sandbox-friendly git implementation (a Swift/library binding that reads the `.git` directory directly via the user-granted folder scope) instead of spawning a process.

The project folder is already user-selected, so the `.git` directory inside it is within granted scope; the obstacle is process execution, not file access. That points toward a library-based reader over a subprocess if the sandbox stays on.

### 2.3. Bridge and mode changes

Once Swift can produce the base text, the editor needs a diff mode:

- A new bridge method, for example `loadDiff(current:base:)`, serializing both documents the way `load(...)` serializes one today.
- A corresponding `window.editorBridge.showDiff(...)` on the JS side that builds a `MergeView` instead of the normal single `EditorView`. Whether this reuses the same web view in a different mode or loads a separate page is a JS-side decision, but the bridge contract is defined here.
- A menu item and notification (e.g. `toggleDiffView`) to enter and leave the mode, following the same pattern as every other command.

### 2.4. Editability and saving

A merge view has two sides. The expected behavior is that the working-copy side stays editable and the base (committed) side is read-only. The existing save path assumes one editable document, so diff mode either disables saving or saves only the working-copy side. We should decide whether diff mode is purely a viewer or also an editing surface; the simpler first version is read-only, which sidesteps the save question entirely.

### 2.5. Choosing what to compare

The first version can diff against `HEAD` only. Anything richer (a specific commit, a branch, or the staged version) needs a small picker UI and the corresponding git invocation, but none of that changes the architecture above; it only changes the argument passed to the git read in section 2.1.
