# Blaze

## 1. Overview
### 1.1. Purpose

`blaze` is a file tracker for development stages. It is inspired by `git`, and remains analogous to it, in that it lives inside a project directory as a hidden folder, is readable by any tool, is agnostic to file formats, and has a defined write interface so that multiple tools can interact with it consistently. However, `blaze` is *not* a version control software. Instead, it tracks development stages, where a piece is understood within a taxonomy of lifecycle shared over a project (e.g., loose note, active draft, review, etc.).

### 1.2. Installation and Files

Blaze is a Python CLI installed into a virtual environment, wherein the `blaze` command is loaded onto `PATH`.

`blaze/` contains the Python source files.

`.venv/` is the virtual environment path. Run `.venv/Scripts/activate` for activation.

## 2. Usage of Blaze
### 2.1. Marks

Tracking a file in blaze is called "marking," invoked by the `blaze mark <type> <path>` command. A mark designates where in the lifecycle a given file lives; or, if not in the standard lifecycle, what kind of role it serves. The marks themselves need names that feel natural to a writer rather than a developer. The following are the default marks included when `blaze` is initiated within a directory.

| Name | Meaning | Indicated in `marks.toml`? | Hierarchy |
| --- | --- | --- | --- |
| Ignored | not visible to blaze | No | N/A |
| Untracked | visible to blaze but not tracked | No | N/A |
| Note | Just a note | Yes | N/A |
| Idea | An idea worth thinking about | Yes | 0 |
| Try | Trying to see if idea (or note) is worth developing into a draft | Yes | 1 |
| Working | Being written into a draft, but fragmentary and incomplete | Yes | 2 |
| Draft | A draft. Has a beginning, middle, and end, but still needs editing | Yes | 3 |
| Review | A draft that has been completed in one sense or another | Yes | 4 |
| Commit | A draft is at a good point; editor or other tool may choose to set file to read-only | Yes | 5 |
| Shelve | Don't need to look at this anymore but not deleting because it may be needed in the future | Yes | N/A |

The "hierarchy" numbers represent stages in the lifecycle. Each user is free to use or ignore these numbers if names alone are sufficient. The benefit of numbered stages is that you can easily "bump" a file to a different stage in its life.

These mark definitions live in `marks.toml` in the `[marks]` section, and serve as the registry of mark types within a given project. See [3. Internal Formatting](#3-internal-formatting) for more.

### 2.2. Subcommands

| Command | Description | Options |
| --- | --- | --- |
| `init` | Initialize blaze in the current directory. All files are "untracked" until they are either marked or included in `ignore.txt`. | |
| `mark <mark-type> <path>` | Mark a file or all files in a directory. | |
| `unmark <path>` | Restore a file or all files in a directory to "untracked". | |
| `check [path]` | Show which mark a file has. With a directory path, groups all tracked files in that directory by mark. With no argument, lists all tracked files across the project. | |
| `seek <mark-type> [path]` | List all files that have the given mark. | `[path]`: limit search to that directory. |
| `bump <up\|down> <path>` | Re-mark a file with the next or previous mark in the hierarchy. Does not support directory-level action. | |
| `log [path]` | Show mark and bump history from `history.log`. | `[path]`: filter history for a specific file or directory. |
| `undo <n>` | Undo the last `n` mark or bump actions recorded in `history.log`. | |
| `clean [path]` | Remove all stale references to file paths that no longer exist. | `[path]`: limit scope to that directory. `--preview`: show which paths would be cleaned without taking action. |
| `refresh [path]` | Update stored fingerprints to reflect the current contents of tracked files. Run this after editing files and before renaming or moving them so that `rename` can detect subsequent moves correctly. | `[path]`: limit scope to a specific file or directory. |
| `rename` | Auto-detect files that have been moved or renamed by comparing stored fingerprints against untracked files on disk. | `--preview`: show detected renames without applying them. |
| `rename <old-path> <new-path>` | Manually update blaze's record when a file has been moved or renamed. | `--dir`: treat both paths as directories. `--preview`: show which files would be affected without taking action. |
| `register <mark-name> [description]` | Register a new mark type. Without placement options, hierarchy is set to N/A (outside the bump chain). | `--after <other-mark>`: place new mark immediately after `<other-mark>` in the hierarchy, shifting others up. `--before <other-mark>`: place new mark immediately before `<other-mark>`, shifting others up. `--hierarchy <n>`: place new mark at level `n`, shifting others up. |
| `remove <mark-name>` | Remove a mark type from the registry. All files with that mark revert to untracked. | `--preview`: show which files would be affected without taking action. |
| `replace <old-name> <new-name>` | Rename a mark type and update all files that carry it. | `--preview`: show which files would be affected without taking action. |

## 3. Internal Formatting
### 3.1. Directory Structure

A blaze-tracked directory has the following `.blaze/` subdirectory:

```
.blaze/
    marks.toml
    history.log
    ignore.txt
```

### 3.2. The TOML File

`marks.toml` has four sections: `[marks]`, `[hierarchy]`, `[files]`, and `[hashes]`.

**`[marks]`** is the registry of mark types for the project. Each entry maps a mark name to its description. This section is populated with defaults on `blaze init` and is modified by `register`, `remove`, and `replace`.

**`[hierarchy]`** maps mark names to their position in the bump chain. Only marks that participate in `bump` are listed here; absence from this section means hierarchy is N/A. All levels must be unique; there's a one-to-one match between marks and heirarchy levels. This section is modified alongside `[marks]` whenever hierarchy-relevant commands are run.

**`[files]`** maps file paths to their current mark. Only tracked files appear here; untracked and ignored files are absent. This section is the primary read target for external tools.

**`[hashes]`** maps file paths to a SHA-256 fingerprint of their contents at the time they were last marked, bumped, or refreshed. This section is used internally by `rename` (no-args form) to detect files that have been moved or renamed. It is updated by `mark`, `bump`, and `refresh`, and is kept in sync with `[files]` by `unmark`, `rename`, `clean`, and `remove`. External tools can ignore this section.

A `marks.toml` after `blaze init` looks like this:

```toml
[marks]
note    = "Just a note"
idea    = "An idea worth thinking about"
try     = "Trying to see if idea is worth developing"
working = "Being written, but fragmentary and incomplete"
draft   = "Has a beginning, middle, and end; needs editing"
review  = "Draft completed in one sense or another"
commit  = "At a good point; editor may choose to set file to read-only"
shelve  = "Not needed now but kept for future reference"

[hierarchy]
idea    = 0
try     = 1
working = 2
draft   = 3
review  = 4
commit  = 5

[files]

[hashes]
```

### 3.3. The Log File

`history.log` records only `mark` and `bump` actions — the two commands that change a file's mark. All other write actions (`unmark`, `rename`, `clean`, `register`, `remove`, `replace`) are not logged. `undo` can only reverse entries that appear in this log.

Each line follows this format:

```
timestamp | action | path | old-mark → new-mark
```

Example:

```
2026-01-15T09:32:00 | mark | topics/mind.md   | working → shelve
2026-01-15T10:15:33 | bump | topics/clock.md  | note → try
2026-01-16T14:02:11 | mark | notes/coffee.txt | untracked → notes
```

`undo <n>` reads the last `n` lines and reverses them in order, restoring each file to its recorded prior mark. If a file's current mark no longer matches the "new" value in the log entry (e.g., it was subsequently changed by an unlogged action), `undo` will flag that entry and skip it rather than silently overwrite.

### 3.4. The Ignore File

This one works exactly like `.gitignore`.
