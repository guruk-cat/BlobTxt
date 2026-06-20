# Multiple Mini Views Plan

## 1. Goal

Allow more than one mini view open at once within a single app session. Today the mini view is a singleton: one `Window` scene driven by the single `store.miniViewURL`. This plan lifts that to a window per blob, so several blobs can each float in their own editor-only window alongside the main editor.

## 2. What is already in place

The Phase 1–3 I/O refactor did the hard part. The data layer is already correct for N surfaces and needs almost no change:

- `LifecycleStore` reference-counts holders per blob (keyed by resolved path). Several mini views on different blobs, or a mini view and the main editor on the same blob, are already legal: `acquire` hands back the shared `BlobContent` and bumps the count, `release` flushes-then-evicts only on the last holder.
- Reconciliation is broadcast by URL. `.blobContentDidSave` carries the blob URL, and every `EditorMonitor` on that path reconciles. This already fans out to any number of surfaces.

Rename and move repointing also already work, by remount. Both the main editor and the current mini view key their `EditorMonitor` on the blob URL via `.id(url)`. Changing that URL tears down the old monitor and mounts a new one, and that remount is what runs `LifecycleStore.release(old)` then `acquire(new)` (`EditorMonitor` `onDisappear`/`onAppear`). So the path-key transition is handled by the existing refcounted release/acquire, which is already N-surface-safe.

The consequence is that this change does not need a new `LifecycleStore.rekey`, does not need a mutable `BlobContent.url`, and does not need an `AppDelegate` change. The bulk of the work is in the scene definition and per-window coordination, not the I/O core.

## 3. The model

### 3.1. One window per blob, instanced by value

Replace the singleton `Window` scene with a value-instanced group:

```swift
WindowGroup(id: "mini-view", for: URL.self) { $url in
    if let url { MiniView(url: $url) ... }
}
```

`openWindow(id: "mini-view", value: blobURL)` opens a window for that blob. A window is pinned to one blob for its life; opening a different blob opens a different window. SwiftUI deduplicates by the scene value, so opening a blob that already has a mini window focuses that window instead of duplicating it. That dedup is the desired "open in mini" behavior and is free.

### 3.2. Decisions locked

These were settled before writing this plan:

- Pinned, one window per blob. No in-place blob swapping inside a mini window.
- Rename repoints the existing window in place (which, as in §2, is a remount that preserves no live scroll but reloads the renamed file).
- Two mini views on the same blob are not allowed; reopening dedups to the existing window.

## 4. Changes by file

### 4.1. `App/BlobTxtApp.swift`

Change the mini-view scene from `Window("Mini View", id: "mini-view")` to `WindowGroup(id: "mini-view", for: URL.self)`, guarding on a non-nil value. Add the move and delete notification names used for cross-window coordination (§5).

### 4.2. `Views/MiniView.swift`

The largest single edit. The window now receives its blob as the scene value rather than reading `store.miniViewURL`.

- Take the blob URL from the scene (a `Binding<URL?>`), and drive the mounted `EditorMonitor`'s `.id` from it.
- Remove the `onChange(of: store.miniViewURL)` swap branch. A window never swaps blobs in place, so the flush-outgoing-then-mount-incoming logic is gone.
- Remove the singleton teardown hacks. A `WindowGroup` window is genuinely destroyed on close, so the `displayedURL = nil` "force reload on reopen" trick and the `isClosing` guard against re-closing are no longer needed. Reopening is a fresh window that mounts and re-acquires from `LifecycleStore`.
- Keep `MiniWindowDelegate`. The async `getContent` flush before the webview tears down is still required so a close commits uncommitted edits to `BlobContent`.
- Add listeners for the move and delete broadcasts (§5) so the window self-repoints or self-closes.

### 4.3. `Views/ContentView.swift`

- `openMiniView` handler: replace `store.miniViewURL = url; openWindow(id:)` with `openWindow(id: "mini-view", value: url)`. Keep the existing "flush the main editor first if it holds this blob" guard, so the mini view opens on the latest committed content.
- Project change (`onChange(of: store.currentProject?.url)`): the single `store.miniViewURL = nil` becomes a broadcast that closes every open mini window (§5.3).

### 4.4. `Views/Sidebar/FileNavigatorView.swift`

- `commitRename`, `dragEnded`, `performDelete`: replace the `store.miniViewURL` mutations with the move and delete broadcasts (§5). The `activeEditorURL` repointing stays as direct mutation, since the main editor is still singular.
- Remove the `.disabled(sameFile(store.miniViewURL, node.url))` "already in mini" gate on the context menu. Value dedup already focuses an existing window, so the gate is obsolete.
- Extract the match-and-rebase math (direct match, and rebasing a blob path onto a moved folder's new location) into a small shared helper, so both the navigator's `activeEditorURL` repoint and each mini window can apply it independently.

### 4.5. `Services/ProjectStore.swift`

Remove the `miniViewURL` property and its doc comment. Nothing persists it and no single value tracks the mini view anymore.

## 5. Cross-window coordination

With N independent windows, the navigator can no longer poke one shared value. It broadcasts the raw filesystem change, and each window decides for itself whether it is affected.

### 5.1. Rename and move

The navigator posts a move event carrying the old path, the new path, and whether the moved item was a directory. Each `MiniView` applies the shared helper to its own blob URL: a direct match repoints to the new path, and a blob living inside a moved folder rebases onto the folder's new location. Repointing changes the URL the `EditorMonitor` is keyed on, which remounts it and runs the existing release/acquire key transition.

### 5.2. Delete

The navigator posts a delete event carrying the deleted path. Each `MiniView` whose blob is that path, or lives under that path, closes itself without writing back (the file is gone). This mirrors the current delete behavior, which closes the mini view with its save skipped.

### 5.3. Project close

A project change closes every open mini window, since their blobs belong to the previous project. `ContentView` posts one notification on project change that every `MiniView` observes and closes on. This preserves the current behavior, where a project change clears the mini view without writing it back.

### 5.4. Key-window detection

No change. `WindowAccessor` already stamps every mini window with the `MiniView.windowID` identifier, so `AppDelegate`'s Cmd+E check (key window's identifier equals that id) still holds for any number of mini windows.

## 6. SwiftUI behaviors to verify during implementation

These are relied on but should be confirmed rather than assumed:

- `openWindow(id:value:)` focuses an existing window with an equal value instead of opening a second one (the dedup in §3.1).
- A `WindowGroup(for: URL.self)` does not spuriously open a nil-value window on launch or via state restoration; the per-window `isRestorable = false` and the nil guard hold.
- Whether writing the scene-value `Binding` from inside `MiniView` (to keep the window's dedup key in sync after a rename) behaves cleanly. If it does not, the window keeps a local repoint state and accepts that a rename-then-reopen can momentarily miss dedup; if it does, the dedup key stays correct after a rename.

## 7. Out of scope and known limitations

- Rename repoints by remount, so it reloads the renamed file and restores cached rather than live scroll. This matches today's single-mini behavior.
- Uncommitted keystrokes present at the instant of a rename are lost across the remount, as they are today. Committed content is safe.
- Project close and delete close affected mini windows without writing back, matching current behavior. Revisiting whether project close should flush first is a separate decision.
- Going value-based makes SwiftUI synthesize a disabled Save item bound to Cmd+S, which captures the key equivalent so the custom Save command stops firing. Cmd+S is intercepted in the `AppDelegate` key monitor instead, the same pattern already used for Cmd+E and Cmd+F. Other menu shortcuts are unaffected.
