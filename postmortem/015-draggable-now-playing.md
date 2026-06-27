# Draggable Now-Playing Child Frame

## Context

ytm-radio's now-playing child frame is intentionally compact and undecorated.
That makes it visually lightweight, but it also removes the normal window-manager
title bar users would drag to move it. The existing render path also re-fits and
repositions the frame after track updates, so a naive `set-frame-position` drag
would be overwritten by the next refresh.

## Decision

Let mouse users drag any non-button area of the graphical child-frame view. The
now-playing mode map owns the background drag gesture, while playback buttons
keep their existing click behavior.

Remember the dragged pixel position only in runtime state for the current child
frame lifecycle. Rendering, track changes, and parent-frame resize handling use
that manual position when present, constrained to the parent frame bounds.
Deleting the now-playing frame clears the manual position.

## Why

Dragging the whole non-button surface avoids adding a visible handle to a compact
surface. Excluding button events keeps transport controls reliable and leaves
keyboard-only operation unchanged.

Runtime-only position state keeps the package behavior predictable: ytm-radio
still renders from current track/player state and does not persist window-system
coordinates across sessions, displays, or Emacs frames.

Constraining the remembered position during refresh and resize prevents the
child frame from drifting fully offscreen after the parent frame changes size.

## Follow-up

If users want persistent placement later, add an explicit customizable anchor or
saved position model instead of silently persisting ad hoc drag coordinates.
