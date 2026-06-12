# To-Do
## 1. Command + Click

`Cmd + click` on a link in the editor (i.e., clicking on "www.wikipedia.org") is already routed to open the link (i.e., in the system's default browser). But there's no visual indication. A font color change based on hover, when `Cmd` is held, is needed. Right now links in hyperlink syntax is rendered with `--text-muted` color. For hover indication, `--meta-indication` color would work.

## 2. Local Hyperlinks and Images

Editor support for links to local files, of headings within a blob, and autocomplete thereof. So, basically how VS code handles those things, or how a README in a git repo will have links to other files and the browser takes you to the corresponding file.

Image support by the same token. Image should use standard markdown syntax for images. 

This also means that the file navigator now lists image files; and because now Markdown isn't the only format supported, it should stop stripping file extensions from file names. 

And the "editor" region will need some way to display an image instead of text. Again, kind of like how VS code does it. This may or may not mean that we need to build some sort of separate, non-CodeMirror JS environment that will bridge onto Swift.

And within an editor showing a blob containing an image via an image link syntax, a tooltip view on mouse hover over the link, showing a preview of the image. Not sure if CodeMirror 6 already has something built for this purpose, or if I need to set up something custom.
