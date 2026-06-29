# Side-Window Now-Playing

## Context

ytm-radio originally exposed now-playing through a child frame or a regular
buffer. A full-width music bar should appear once per frame, not once per Emacs
window. Inspecting Emacs display code confirmed that `header-line-format` and
`tab-line-format` are owned by leaf windows. The tab bar is frame-level, but it
is semantically tied to tab management and looks out of place for users who do
not use tabs.

Emacs side windows are ordinary windows reserved at a frame side and managed by
`display-buffer-in-side-window`. They are intended for auxiliary UI around the
main window area, can be marked dedicated, and can be protected from normal
window cycling and `delete-other-windows`.

## Decision

Add `side-window` as a third `ytm-radio-display-style`. The style displays the
now-playing buffer in a dedicated top side window with a fixed height, no mode
line, no header line, no fringes, no scroll bars, and `no-other-window` /
`no-delete-other-windows` parameters. Hiding now-playing deletes only that side
window.

The side-window bar reuses existing player state, progress formatting, cover
cache, title marquee, and transport-control specs. Unlike the child-frame view,
it renders a single compact row because the frame layout itself provides the
bar-like placement.

## Why

A default header line repeats in every window that inherits it, so it does not
satisfy the single full-frame music bar requirement. The tab bar appears once per
frame, but using it for playback controls overloads tab-management UI and can
surprise users who do not otherwise enable tabs.

A top side window is the best stock Emacs fit: it is frame-local, reserves real
layout space instead of floating over text, composes with normal window layout,
and uses standard buffer/window primitives rather than a custom pseudo-tab or an
overlaid child frame.

## Follow-up

If users want the bar to float above content instead of reserving layout space,
keep the existing child-frame display style and consider adding a top-anchored
child-frame variant with explicit resize and multi-frame lifecycle handling.
