#!/usr/bin/env python3
"""
Migration script: convert BlobTxt JSON blobs to Markdown files.

For each <blobID>.json in the project directory, this script:
  1. Converts TipTap JSON content → Markdown (with Pandoc-style footnotes)
  2. Derives a human-readable filename from the blob's title or first text line
  3. Writes <human-readable-name>.md into the appropriate subfolder (based on the folder structure in project.json)

Usage:
  python migrate_blobs.py <project-dir> [--dry-run]

The script does NOT delete the original .json files or project.json.
Run with --dry-run to preview filenames without writing anything.
"""

import json
import os
import re
import sys
import unicodedata


# Conversion: TipTap JSON → Markdown

def slugify(text: str) -> str:
    # Convert a title string to a safe filename (no extension).
    text = unicodedata.normalize('NFKD', text)
    text = text.encode('ascii', 'ignore').decode('ascii')
    text = text.lower()
    text = re.sub(r'[^\w\s-]', '', text)
    text = re.sub(r'[\s_-]+', '-', text).strip('-')
    return text or 'untitled'


def inline_to_md(nodes: list) -> str:
    # Serialize a list of inline nodes (text, marks, footnoteReference) to Markdown.
    parts = []
    for node in nodes:
        t = node.get('type')
        if t == 'text':
            text = node.get('text', '')
            marks = {m['type'] for m in node.get('marks', [])}
            link_mark = next((m for m in node.get('marks', []) if m['type'] == 'link'), None)
            # Apply marks inside-out: code > bold/italic/underline > link
            if 'code' in marks:
                text = f'`{text}`'
            else:
                if 'bold' in marks and 'italic' in marks:
                    text = f'***{text}***'
                elif 'bold' in marks:
                    text = f'**{text}**'
                elif 'italic' in marks:
                    text = f'*{text}*'
                if 'underline' in marks:
                    # No standard Markdown underline; use HTML
                    text = f'<u>{text}</u>'
            if link_mark:
                href = link_mark.get('attrs', {}).get('href', '')
                text = f'[{text}]({href})'
            parts.append(text)
        elif t == 'footnoteReference':
            num = node['attrs']['referenceNumber']
            parts.append(f'[^{num}]')
        elif t == 'hardBreak':
            parts.append('  \n')
    return ''.join(parts)


def block_to_md(node: dict, fn_map: dict, depth: int = 0) -> str:
    # Serialize a single block node to a Markdown string
    # fn_map: dict mapping data-id → referenceNumber, built from the whole doc
    # depth: indentation level inside lists
    
    t = node.get('type')
    content = node.get('content', [])
    indent = '  ' * depth

    if t == 'paragraph':
        text = inline_to_md(content)
        return indent + text if text.strip() else ''

    elif t == 'heading':
        level = node['attrs']['level']
        text = inline_to_md(content)
        return '#' * level + ' ' + text

    elif t == 'blockquote':
        lines = []
        for child in content:
            block = block_to_md(child, fn_map, depth=0)
            for line in block.splitlines():
                lines.append('> ' + line)
        return '\n'.join(lines)

    elif t == 'bulletList':
        items = []
        for item in content:
            items.append(list_item_to_md(item, fn_map, bullet='-', depth=depth))
        return '\n'.join(items)

    elif t == 'orderedList':
        items = []
        start = node.get('attrs', {}).get('start', 1)
        for i, item in enumerate(content):
            items.append(list_item_to_md(item, fn_map, bullet=f'{start + i}.', depth=depth))
        return '\n'.join(items)

    elif t == 'image':
        attrs = node.get('attrs', {})
        src = attrs.get('src', '')
        alt = attrs.get('alt', '')
        title = attrs.get('title', '')
        if title:
            return f'![{alt}]({src} "{title}")'
        return f'![{alt}]({src})'

    elif t == 'footnotes':
        # Rendered separately at the end of the document
        return ''

    return ''


def list_item_to_md(node: dict, fn_map: dict, bullet: str, depth: int) -> str:
    # Serialize a listItem node, handling nested lists.
    indent = '  ' * depth
    content = node.get('content', [])
    if not content:
        return f'{indent}{bullet} '

    lines = []
    first = True
    for child in content:
        if child['type'] in ('bulletList', 'orderedList'):
            lines.append(block_to_md(child, fn_map, depth=depth + 1))
        else:
            text = block_to_md(child, fn_map, depth=0)
            if first:
                lines.append(f'{indent}{bullet} {text}')
                first = False
            else:
                # Continuation paragraph inside list item
                lines.append(f'{indent}  {text}')
    return '\n'.join(lines)


def render_footnotes(doc: dict) -> str:
    # Extract the footnotes container from the doc and render Pandoc-style definitions.
    # Returns an empty string if there are no footnotes.
    footnotes_node = None
    for node in doc.get('content', []):
        if node.get('type') == 'footnotes':
            footnotes_node = node
            break
    if not footnotes_node:
        return ''

    lines = []
    for fn in footnotes_node.get('content', []):
        # id is "fn:N" — extract N
        raw_id = fn['attrs'].get('id', '')
        num = raw_id.replace('fn:', '') if raw_id.startswith('fn:') else raw_id
        # Footnote body: usually one paragraph, but can be multiple blocks
        body_parts = []
        for child in fn.get('content', []):
            body_parts.append(block_to_md(child, fn_map={}, depth=0))
        body = ' '.join(p for p in body_parts if p)
        lines.append(f'[^{num}]: {body}')

    return '\n'.join(lines)


def doc_to_markdown(doc: dict) -> str:
    # Convert a TipTap doc node to a Markdown string.
    # Build footnote reference number map: data-id → referenceNumber
    fn_map = {}
    def collect_refs(node):
        if not isinstance(node, dict):
            return
        if node.get('type') == 'footnoteReference':
            fn_map[node['attrs']['data-id']] = node['attrs']['referenceNumber']
        for c in node.get('content', []):
            collect_refs(c)
    collect_refs(doc)

    blocks = []
    for node in doc.get('content', []):
        if node.get('type') == 'footnotes':
            continue
        md = block_to_md(node, fn_map)
        blocks.append(md)

    body = '\n\n'.join(b for b in blocks if b)

    footnote_section = render_footnotes(doc)
    if footnote_section:
        return body + '\n\n' + footnote_section + '\n'
    return body + '\n'


# Filename derivation

def derive_title(doc: dict) -> str:
    # Return the blob's display title
    # first H1 heading if present, 
    # otherwise the first non-empty line of text.
    for node in doc.get('content', []):
        if node.get('type') == 'heading' and node.get('attrs', {}).get('level') == 1:
            return inline_to_md(node.get('content', [])).strip()
    for node in doc.get('content', []):
        if node.get('type') == 'paragraph':
            text = inline_to_md(node.get('content', [])).strip()
            # Strip any markdown formatting characters for the slug
            text = re.sub(r'[*_`\[\]()#]', '', text)
            if text:
                # Truncate long titles
                return text[:60]
    return ''


def unique_filename(desired: str, used: set) -> str:
    # Return `desired` if not in `used`, otherwise append -2, -3, ... until unique.
    if desired not in used:
        return desired
    i = 2
    while True:
        candidate = f'{desired[:-3]}-{i}.md'
        if candidate not in used:
            return candidate
        i += 1


# Main migration logic

def migrate(project_dir: str, dry_run: bool = False):
    project_json_path = os.path.join(project_dir, 'project.json')
    if not os.path.exists(project_json_path):
        print(f'Error: no project.json found in {project_dir}')
        sys.exit(1)

    with open(project_json_path) as f:
        project = json.load(f)

    # Build folder ID → name map
    folder_map = {f['id']: f['name'] for f in project.get('folders', [])}

    # Build blob ID → folder name map
    blob_folder = {b['id']: folder_map.get(b.get('folderID'), '') for b in project.get('blobs', [])}

    # Track used filenames per folder to avoid collisions
    used_names: dict[str, set] = {}

    results = []

    for blob_entry in project.get('blobs', []):
        blob_id = blob_entry['id']
        src_path = os.path.join(project_dir, f'{blob_id}.json')
        if not os.path.exists(src_path):
            print(f'  Warning: missing blob file {blob_id}.json — skipping')
            continue

        with open(src_path) as f:
            doc = json.load(f)

        # Prefer an explicit title stored in the project.json blob entry,
        # then fall back to deriving one from the document content.
        stored_title = blob_entry.get('title', '').strip()
        title = stored_title if stored_title else derive_title(doc)
        base_slug = slugify(title) if title else 'untitled'
        desired_name = base_slug + '.md'

        folder_name = blob_folder.get(blob_id, '')
        folder_key = folder_name  # used as dict key for collision tracking

        if folder_key not in used_names:
            used_names[folder_key] = set()

        final_name = unique_filename(desired_name, used_names[folder_key])
        used_names[folder_key].add(final_name)

        # Destination path: <project_dir>/<folder_name>/<filename>.md
        # (or <project_dir>/<filename>.md if blob has no folder)
        if folder_name:
            dest_dir = os.path.join(project_dir, folder_name)
        else:
            dest_dir = project_dir
        dest_path = os.path.join(dest_dir, final_name)

        markdown = doc_to_markdown(doc)
        results.append((src_path, dest_path, markdown))

    # Report and write
    for src_path, dest_path, markdown in results:
        rel_src = os.path.relpath(src_path, project_dir)
        rel_dest = os.path.relpath(dest_path, project_dir)
        print(f'  {rel_src}  →  {rel_dest}')
        if not dry_run:
            os.makedirs(os.path.dirname(dest_path), exist_ok=True)
            with open(dest_path, 'w', encoding='utf-8') as f:
                f.write(markdown)

    if dry_run:
        print(f'\nDry run — {len(results)} blobs would be written.')
    else:
        print(f'\nDone — {len(results)} blobs written.')


if __name__ == '__main__':
    args = sys.argv[1:]
    dry_run = '--dry-run' in args
    dirs = [a for a in args if not a.startswith('--')]
    if not dirs:
        print(__doc__)
        sys.exit(0)
    migrate(dirs[0], dry_run=dry_run)
