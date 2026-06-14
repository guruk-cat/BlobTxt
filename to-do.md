# To-Do List

## 1. Metadata Panel

The sidebar holds four panels, one of them being the [File Navigator](docs/file-navigator.md) and three others being placeholders for future features. The Blob Metadata panel is one of them.

### 1.1. UI Prepwork

1. Duplicate the layout of File Navigator into a new file, remove everything except for the skeleton, and put a "Blob Metadata" header in the exact style of the "Project Name" header of the navigator. 
2. Wire it to the floating island. 
3. Clean up dead code in SidebarView.

### 1.2. Metadata I/O

ProjectStore is responsible for I/O at the OS-app border. It will take the blob content and strip the YAML-style frontmatter, and hand it over to the editor-related code. Opposite traffic works the same: YAML frontmatter is appended again before file write.

The Metadata panel is the UI for reading and writing this blob-specific metadata. For now, the planned keys are:

- title
- author(s)
- date
- institution(s)

All are optional, and having a blank front matter won't break other features because ProjectStore strips, holds, and re-appends metadata when anything travels from and to it. These keys will, in the future, be used for producing the front page of blobs when exported to PDFs and whatnot.

Exiting the panel, hitting enter while editing a field, or otherwise defocusing from a field after having edited it, should all result in a write-request to ProjectStore. Then, ProjectStore will store the new metadata and append it on the next save (i.e., whole `.md` file write).

### 1.3. UI Layout

Each key should have a row, with key being printed in `textResting` like the navigator, and in the same HStack, an editable field, a rectangle colored in `surface` with font colored `textBody`. We'll try giving the rectangle a thin border with `borderCard`; not sure if it'll be good or bad. A text field that is focused (i.e., is being renamed) should have a `metaIndication` outline.



## 2. File Operations Panel

File Operations panel (File Ops for short) is another sidebar panel that is currently a blank placeholder.

### 2.1. UI Prepwork

Same as before:

1. Duplicate the layout of File Navigator into a new file, remove everything except for the skeleton, and put a "File Operations" header in the exact style of the "Project Name" header of the navigator. 
2. Wire it to the floating island. 
3. Clean up dead code in SidebarView.

### 2.2. UI Layout

A lot of the features here will be implemented via separate panels that are wider (like that of SettingsView). The panel itself will be more of a host of routes to those other features (and some status indications, perhaps).

The individual items may be buttons, cards, or GroupBoxes; haven't really decided on this. Needs more thought.

Two items that I know for sure that we'll go on there:

1. "Merge Blobs." Service to select and merge Markdown content, and have headings and footnotes re-arranged automatically according to user's preferences.
2. "Page Layout for Print & PDF." A config helper for the custom CSS that will be used in print jobs and PDF exports.

Both of these will need dedicated panels, since they require more space.
