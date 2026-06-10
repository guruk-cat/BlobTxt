# To-Do List

## 1. Links in Editor
### 1.1. Command + Click

`Cmd + click` on a link in the editor (i.e., clicking on "www.wikipedia.org") is already routed to open the link (e.g., in the system's default browser). But there's no visual indication. A font color change based on hover, when `Cmd` is held, is needed. Right now links in hyperlink syntax is rendered with `--text-muted` color. For hover indication, `--meta-indication` color would work.

### 1.2. Wikilinks, Local Hyperlinks, and Images

TBD

## 2. File Navigator
### 2.1. Current State

The navigator is a bare-minimum, flatted list of all blobs within the project directory. Clicking on a blob in the list does post the blob URL so the editor can load, and the corresponding blob is marked with a opacity overlay in the list. That's about it. All the important features were deferred.

### 2.2. New Layout

TBD

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
