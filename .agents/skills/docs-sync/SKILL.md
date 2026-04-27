---
name: docs-sync
description: |
  Synchronize documentation indices and cross-references. Use after adding,
  renaming, moving, or deleting documentation files. Finds orphaned docs, stale
  links, and broken cross-references, then fixes them and reports changes.
---

# docs-sync

## Purpose

Keep documentation indices, cross-reference links, and table-of-contents files consistent after docs are added, renamed, moved, or deleted. Prevent stale links and orphaned pages.

## Required Reads

- `.agents/project.json` -- confirm design facet is enabled
- `docs/` directory listing -- current documentation tree
- Any existing index files (e.g., `docs/index.md`, `docs/overview.md`) -- current state of indices
- `.agents/pm/pm-current-state.md` -- recent changes that may have affected docs

## Procedure

1. List all markdown files under `docs/` recursively.
2. Read each existing index or table-of-contents file in the docs tree.
3. Compare the file list against index entries. Identify:
   - Files present on disk but missing from indices (orphaned docs).
   - Index entries pointing to files that no longer exist (stale links).
   - Cross-reference links within docs that point to renamed or moved targets.
4. For each orphaned doc, add an entry to the appropriate index with the file path and a one-line summary derived from the document's first heading.
5. For each stale link, either update the link to the new location or remove the entry and flag it in the output.
6. For broken cross-references inside documents, fix the link target. If the target cannot be determined, insert a `<!-- TODO: fix broken link -->` comment and list it in the output.
7. If `docs/overview.md` exists, verify its section list matches the current doc tree structure. Update if needed.
8. Write a brief sync report to the user listing changes made and any items needing manual review.

## Output

- Updated index and table-of-contents files under `docs/`
- Fixed cross-reference links within documentation files
- Sync report listing: files added to indices, stale links removed, broken links flagged

## Completion Criteria

- Every markdown file under `docs/` appears in at least one index.
- No index entry points to a nonexistent file.
- All fixable cross-reference links have been updated.
- Any unfixable links are marked with a TODO comment and reported to the user.

## Error Handling

- If the design facet is not enabled in `project.json`, warn the user and ask whether to proceed anyway.
- If no `docs/` directory exists, stop and tell the user there is nothing to synchronize.
- If an index file uses a format that cannot be parsed, skip it and report it as needing manual review.
