# To-Do List

## 1. Links in Editor
### 1.1. Command + Click

`Cmd + click` on a link in the editor (i.e., clicking on "www.wikipedia.org") is already routed to open the link (e.g., in the system's default browser). But there's no visual indication. A font color change based on hover, when `Cmd` is held, is needed. Right now links in hyperlink syntax is rendered with `--text-muted` color. For hover indication, `--meta-indication` color would work.

### 1.2. Wikilinks, Local Hyperlinks, and Images

TBD

## 2. File Navigator
### 2.1. Current State

The navigator is a bare-minimum, flatted list of all blobs within the project directory. Clicking on a blob in the list does post the blob URL so the editor can load, and the corresponding blob is marked with a opacity overlay in the list. That's about it. All the important features were deferred.

### 2.2. File Layout

First, the project title needs to be outside of the scrollable view. This probably means that a `VStack` needs to own the `ScrollView`.

Next, the project contents need to be presented in a nested view that reflects the directory structure. This includes collapsible folder rows, indicated with ">" and "v" chevrons; indents for nested contents; and sorting by type in addition to alphebetical order, where folders come before blobs and other files.

On the same row as the project name header, and on the right side of it, should be new folder and new blob buttons. These buttons should be SF icons. The icons should be `textBody` by default, `metaIndication` when hovered, and briefly glow in `metaConfirmation` when clicked.

This will also require some way for the navigator to track the *context* directory, wherein new folders and blobs will be created when prompted. This should be whatever folder whose row was last opened, given that it is not currently collapsed. If there is no such folder, context should be set to the project root. For clarification, if folder A was opened, then folder B opened, then folder B closed, there is no subdirectory that matches the context; and the project root is therefore the context. The context folder is NOT the last folder that was opened among the folders currently open. Rather, it is the last folder that was opened, given that this specific folder is still open. The logic also applies to subdirectories, i.e., folders inside folders.

Folder and blob names in the navigator should use `textResting` by default. Blobs should have a file icon left to them where a folder would have a chevron.

For blobs in the navigator, when a blob is open in the editor (i.e., its URL is the active one), the corresponding row in the navigator should still have the metaIndication opacity overlay as it does right now. This does not apply to folders.

Each row should be an `HStack`, such that some sort of indication symbol or character can be appended at the right-end of the row. As to what this indication is, that's the scope of future features.

Both for folders and blobs, the *whole row* should be clickable, not just the chevron, or the icon, or the text label.

### 2.3. Mode Toggle

At the bottom of the navigator, and outside of the `ScrollView`, there should be a toggle switch, sandwiched to the left and right by two text labels. The two labels should read "Git" and "Blaze." The "Git" label should be right-aligned within its position, and the "Blaze" label left-aligned. The toggle itself should be centered within the HStack. This whole group should be labeled, above them, as "MODE:" with font style and color matching those of the project name header. So, the visual layout is as below:

| MODE:                  |
|    Git (toggle) Blaze  |
|                        |

Since this is not an of/off switch, but rather a binary selector, there should not be a color indication within the switch itself. The actual functionalities of the toggle is planned for the future.

### 2.4. Margins

Uniform margins to the top and bottom of the panel should be used. `8px` should be tried as the initial value, and adjusted after testing. This probably means that the main `VStack` at the top-layer of the panel needs uniform margins. 

Similarly, uniform margins to the left and right of the panel should be used, although these margins need not be as thick as the vertical margins.

### 2.5. Relation to Rest of the App

Currently, the SidebarView occupies a space left to the editor and alternate between 0 and a fixed value for its width. This means that the every time a panel (which sits inside the SidebarView) opens or closes, the editor is displaced (i.e., moved and resized).

I want the panel (and with it, the floating island of buttons in `FloatingIslandView`) to instead sit on top of the editor, while still flushed to the left of the window. The side margins within the editor means that this will, in most cases, not obscure the text for the user. The difference at the code level will probably be the following. Instead of an HStack that contains the sidebar and the editor, there will be a ZStack wherein the sidebar sits on top of the editor, and the top layer holds the sidebar + the remaining space in that layer, which will just be transparent as to show the editor.

The floating island may complicate this a little further. A review of the exact layout of the app is required before writing code.

The width of the panel and the floating island when expanded remain unchanged.

## 3. Syntax Highlighting
### 3.1. Brackets

A pair of brackets, where each and both of those brackets are sandwiched by non-syntax characters, needs to be treated as regular text. Examples are below.

| Literal string | regular text or syntax |
| --- | --- |
| Look at this: ![some text](some_link) Haha. | syntax: image |
| Look at this: [some text](some_link) Haha. | syntax: hyperlink |
| Look at this.[^some text] Haha. | syntax: reference |
| Look at this [some text] Haha. | Regular text |

There already exists some logic in the code to differntiate in the case of footnotes. For instance, `![^some text]`, when there is no `(some_link)` immediately following, is treated as a footnote, wherein `!` is regular text and `[^some text]` is recognized as footnote reference. A similar logic is required for the case of a pair of brackets that is neither link nor footnote.

### 3.2. Differentiated Colors for Markdown Syntax

Some syntax need to be inconspicuous. Others need to be conspicuous. They need different colors. 

Brackets, parentheses, and chevrons, when used as part of Markdown syntax, need to be inconspicuous. This is currently done with `--text-muted` font color. 

`-` or `*`, when marking a list item or emphasis, need to be conspicuous. This is not considered in the current codebase.

## 4. Git in Editor

The following is about modification indication within the left-side gutter of the editor, not `git diff` in split screen.

