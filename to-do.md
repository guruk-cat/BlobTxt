# To-Do List

## 1. Links in Editor
### 1.1. Command + Click

`Cmd + click` on a link in the editor (i.e., clicking on "www.wikipedia.org") is already routed to open the link (e.g., in the system's default browser). But there's no visual indication. A font color change based on hover, when `Cmd` is held, is needed. Right now links in hyperlink syntax is rendered with `--text-muted` color. For hover indication, `--meta-indication` color would work.

### 1.2. Wikilinks, Local Hyperlinks, and Images

TBD

## 2. Folder Dragging

The navigator currently only supports dragging blobs into folders. 
New feature: drag folder into folder. Same drag mechanism as blobs. Also need to watch out for blaze tracking: run `blaze rename [old-path] [new-path]` for any path changes involved.

## 3. Better nav panel

Dedicated color keys for for row backgrounds, following what's planned for the blaze GUI tool.

Possibly make the blaze indicator column fixed-width and left-align the text?
