# To-Do List

## 1. File Operations Panel

File Operations panel (File Ops for short) is another sidebar panel that is currently a blank placeholder.

### 1.1. UI Prepwork

Same as before:

1. Duplicate the layout of File Navigator into a new file, remove everything except for the skeleton, and put a "File Operations" header in the exact style of the "Project Name" header of the navigator. 
2. Wire it to the floating island. 
3. Clean up dead code in SidebarView.

### 1.2. UI Layout

A lot of the features here will be implemented via separate panels that are wider (like that of SettingsView). The panel itself will be more of a host of routes to those other features (and some status indications, perhaps).

The individual items may be buttons, cards, or GroupBoxes; haven't really decided on this. Needs more thought.

Two items that I know for sure that we'll go on there:

1. "Merge Blobs." Service to select and merge Markdown content, and have headings and footnotes re-arranged automatically according to user's preferences.
2. "Page Layout for Print & PDF." A config helper for the custom CSS that will be used in print jobs and PDF exports.

Both of these will need dedicated panels, since they require more space.

### 1.3. Merge Blobs

This will have a dedicated panel, accessed via the file ops panel, that will sit on top of the app window like the settings panel. We'll call it the "MB" panel for short. It'll have several "layers" corresponding to the stages in the process of merging blobs.

#### 1.3.1. Selection

The left side the MB panel is basically a read-only file navigator: folders expand/collpase on click, but no write-functionalities. 

On the remaining right side of the panel is a drop zone. The user can drag a blob from the navigator portion and drop it into the drop zone. The drag-and-drop UI should use the same mechanism as the one used in the actual navigator.

The drop zone is organized as a numbered list, first-come, first-listed. User can drag to re-order and drag a blob away out of the zone to remove it from list.

When satisfied with the selection and the order, user confirms their selection.

The layout of the panel is as follows. The panel itself is a rounded rectangle, cut in half, the left side colored with a `chromePanel` background to match the regular navigator, and the right side colored with `surface`. Font on the left side and the drag preview matches those of whatever's used in the regular navigator panel. The right side uses `textBody` for fonts. At the bottom-right corner is a "continue" button that glows in `metaIndication` when hovered.

#### 1.3.2. Headings Adjustment

The UI layout of the MB panel is similar: rectangle, cut in half, left side is `chromePanel` background, right side `surface` background. 

The right side is essentially a preview of all the headings that will be included. It should look roughly the same as the editor. (Hence the `surface` background used from earlier.) The left side is a panel for adjustments and preferences, which will be relfected on the right-side preview in live-time.

For instance, if blob A and blob B are being merged, in that order, and both have a level-1 heading and two level-2 headings, the preview should show:

```Markdown
# Heading A

## Subheading from A (1)

## Subjeading from A (2)

# Heading B

## Subheading from B (1)

## Subjeading from B (2)
```

For now, we'll just get the UI working, and think about the user configs once the UI is working.

Something to consider: whether the preview will use another CM6 EditorView, or if we can do something native Swift since it's display-only and doesn't need editor-like interactions. Either way, it'll need to be scrollable.

And as before, at the bottom right, "continue" button.

#### 1.3.3. Metadata

Same rectangle panel, but whole panel is `chromePanel` color. No split.

User specifies (1) file name, and (2) optionally the metadata fields that are specified in the metadata panel.

A button for "Finalize" at the bottom. File is created at project root.