# Standalone Mini View

## 1. Purpose

This document outlines the intended refactor that lets BlobTxt run as a dedicated mini-view editor without ever instantiating a project window. It is a plan, not an implementation log.

## 2. The two modes

BlobTxt runs in one of two modes:

Project mode is the full editor tied to a project directory: sidebar, navigator, git tracking, file operations. This is the existing `ContentView`.

Mini mode is an editor that handles one blob at a time, with no project-level features.

Mini windows themselves come in two flavors that share the same `MiniView` surface but differ in whether they belong to a project:

A tethered mini is opened from a project window's navigator ("Open in Mini View"). It binds to the project's shared `ProjectStore`, follows `blobMoved` and `blobDeleted`, closes on `closeAllMiniViews`, and reconciles through the shared `BlobContent`. This is the current mini view and its behavior does not change.

A standalone mini is opened from Finder. It has no project. It is handed a throwaway `ProjectStore()` only to satisfy the environment requirement, and it ignores every project broadcast.

## 3. Why the launch window is repurposed, not suppressed

At the macOS 13 deployment target, the first `WindowGroup` in the `App` body is auto-instantiated at launch and there is no supported way to stop it. The native control that would suppress it, `Scene.defaultLaunchBehavior(.suppressed)`, is macOS 15 and later. Past attempts to let the project window be born and then hide or detach a mini view fought this and failed.

The refactor inverts the approach: the one guaranteed window is owned by a router view that renders whichever mode the launch resolved to. The project surface is never built in mini mode rather than built and hidden.

## 4. Single process, not separate processes

A Finder double-click routes the open to the already-running BlobTxt process through `application(_:open:)`; it does not spawn a second process. The standalone mini is therefore a separate window, not a separate instance of the app.

This is deliberate. `LifecycleStore.shared` is a single per-process registry, and its single-writer reconciliation only holds within one process. If the same blob is open both in a project window and in a standalone mini, one process keeps them consistent at save boundaries; two processes would each hold their own `BlobContent` and clobber the file on save. Keeping everything in one process preserves that safety.

## 5. The diff

### 5.1. Launch mode

Add an app-level mode that the router reads. It is resolved before the launch window draws.

The project case carries its directory so the launch window opens that project rather than the last-used one. A plain launch with no opened path falls back to a nil directory, which means "open the last-used project" as today.

```swift
enum AppMode {
    case project(URL?)
    case mini(URL)
}
```

The resolution lives in `AppDelegate`. For a launch triggered by opening a path, AppKit calls `application(_:open:)` before `applicationDidFinishLaunching`, so the ordering is reliable and needs no placeholder window. The opened URL is a directory when the path is a project (from Finder on a project folder, or `blobtxt .`) and a file when it is a standalone blob, so the hook branches on that:

```swift
func application(_ application: NSApplication, open urls: [URL]) {
    guard let url = urls.first else { return }
    var isDir: ObjCBool = false
    FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
    launchMode = isDir.boolValue ? .project(url) : .mini(url)
    handledLaunchOpen = true
}

func applicationDidFinishLaunching(_ notification: Notification) {
    if !handledLaunchOpen { launchMode = .project(nil) }
    // existing Cmd-key monitor setup stays here
}
```

The mode is settled in the same run loop the window first draws, so the project surface never flashes before a Finder-opened mini. Additional paths opened while the app is already running arrive through `application(_:open:)` again; those are handled in §5.4, not by re-routing the launch window.

### 5.2. The router

The primary `WindowGroup` hosts a `RootView` that switches on the resolved mode. Because a standalone mini is hard-locked for its session, the switch is one-way and stays trivial.

```swift
struct RootView: View {
    let mode: AppMode

    var body: some View {
        switch mode {
        case .project(let dir):
            ContentView(initialProject: dir)   // nil opens the last-used project
        case .mini(let url):
            MiniView(url: url)
                .environmentObject(ProjectStore())   // throwaway, satisfies the env requirement only
        }
    }
}
```

`EditorMonitor` already guards every use of `store` behind `if !isMini`, so the throwaway store is never read in mini mode.

### 5.3. Tethering carried in the window value

The existing value-based mini group keys on `URL`. Replace the key with a small payload that also carries whether the mini belongs to a project:

```swift
struct MiniRef: Codable, Hashable {
    let url: URL
    let tethered: Bool
}
```

The scene picks the store from the flag:

```swift
WindowGroup(id: "mini-view", for: MiniRef.self) { $ref in
    if let ref {
        MiniView(url: ref.url)
            .environmentObject(ref.tethered ? store : ProjectStore())
            .environmentObject(AppColors.shared)
    }
}
```

A consequence to keep in mind: a tethered and a standalone window on the same blob are now two distinct values and therefore two windows. This is intended, since a Finder open is always its own untethered window.

### 5.4. Routing the two open paths

The navigator's "Open in Mini View" posts a `MiniRef` with `tethered: true`, preserving today's behavior.

File opens that arrive while the app is already running post a `MiniRef` with `tethered: false`, and `ContentView` (or whichever surface owns the `openWindow` action) opens the window. SwiftUI dedups by value, so re-opening the same untethered file focuses its existing window.

Directory opens that arrive while running are a project concern, not a mini one: they route through the existing project-open path on the directory rather than spawning a mini.

## 6. What is deliberately not done

The app is not converted to a `DocumentGroup`. BlobTxt is a project editor, and document-based scenes would be a structural rewrite for no gain.

The deployment target is not bumped to macOS 15 for `defaultLaunchBehavior(.suppressed)`. That would allow genuinely separate project and mini scenes instead of a router branch, but it costs the target bump and still needs the same launch-time mode decision. It is only worth revisiting if macOS 13 and 14 support is dropped for other reasons.

Standalone minis are not promotable to project mode. A mini session is hard-locked, which is what keeps `RootView` a one-way switch.

## 7. Extra work when done

Make it so that BlobTxt can be open via the terminal. It should accept directories (for projects) and file paths (for standalone mini views):

```sh
cd path/to/project/
blobtxt .
```

OR

```sh
cd path/to/some/random/dir/
blobtxt some-file.md
```

This needs no new app-side transport. The directory-versus-file branch in `application(_:open:)` from §5.1 already does the routing; the terminal command only has to hand the path to that hook, which is exactly what `open -a` does. So `blobtxt` is a one-line wrapper on `PATH` rather than a CLI target:

```sh
#!/bin/sh
# blobtxt: open a project dir or a markdown file in BlobTxt
open -a BlobTxt "${1:-.}"
```

`open` resolves relative paths against `$PWD`, so both `.` and `some-file.md` work. Plain `open -a` (no `-n`) routes to the running instance, keeping the single-process rule from §4 intact: a directory and a file opened back-to-back share the one `LifecycleStore`.

Left out until actually needed: a real CLI target, a `-W` wait flag, and multi-path handling. `blobtxt a.md b.md` would open only the first, since the hook reads `urls.first`; add the loop only once opening several at once is a real use.
