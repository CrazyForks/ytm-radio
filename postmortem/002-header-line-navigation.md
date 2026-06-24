# Header Line Navigation

## Context

The browser buffer originally rendered Home, Explore, Library, and Search as a
text tab strip at the top of the buffer. That made the first body line UI
chrome instead of content, duplicated search because `/` already exists, and
made point/navigation interact with view controls.

## Decision

Remove the body tab strip. Show the current browser view and loading state in a
buffer-local header line. Keep navigation keyboard-first:

- `H` switches to Home;
- `E` switches to Explore;
- `L` switches to Library;
- `/` opens Search;
- `b` returns to the previous browser view.

Do not add a generic switch-view command for now.

## Why

This matches Emacs UX better than a fake web tab row. The header line is
buffer-local, visually attached to the content, and does not affect point,
imenu, section movement, or the first rendered section. Search is naturally a
command with history/back behavior rather than a permanent top-level tab.

The direct keys are faster than a selector for the three stable root views.
`g` remains the explicit refresh path, so normal view switching can use cached
content and avoid unnecessary network work.
