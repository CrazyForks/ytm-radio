# Auto-Show Now-Playing

## Context

ytm-radio historically showed now-playing whenever playback switched tracks.
That is a good default for a small music launcher because the user immediately
sees cover art, progress, and transport controls for the newly selected track.

The same behavior is noisy for users who keep ytm-radio open while working in
other buffers. Track changes can happen from queue navigation, automatic retry,
or account stream resolution, and all of those paths previously treated showing
now-playing as part of playback state setup.

## Decision

Keep automatic now-playing display enabled by default, but make it configurable
with `ytm-radio-auto-show-now-playing`.

Only automatic playback-change paths consult that option. The public
`ytm-radio-now-playing` command remains an explicit user action and continues to
show or hide the configured now-playing surface regardless of the automatic
display setting.

## Why

Automatic display and manual display are different intents. Automatic display is
a notification-like behavior attached to track changes; manual display is a
direct command asking for the current playback surface.

Keeping those paths separate preserves the existing out-of-the-box experience
while letting users choose a quieter workflow without losing the command they
use to inspect or dismiss now-playing on demand.
