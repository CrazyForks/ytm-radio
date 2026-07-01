# Current Actions Seek Controls

## Context

The current-track transient started as a compact action surface for playback
and track actions. Seeking was available as direct browser bindings, but the
transient did not expose it, and the direct commands still used the older
prefix-argument behavior.

That made two interaction models coexist: browser keys used fixed seek
behavior, while `C-u` on the public commands changed the amount through Emacs
prefix arithmetic. The transient needed a visible way to set the amount without
adding another hidden fallback path.

## Decision

Use a configured default seek step for direct seek commands and browser
bindings. The current-track transient exposes back, forward, and an explicit
`Seek seconds` option for the current transient session.

The transient seek option is strict: invalid or missing transient seek
arguments are user errors rather than implicit fallbacks. The direct commands
use `ytm-radio-seek-step` instead of interpreting `C-u`.

The transient also exposes now-playing because it is a current playback surface,
and it no longer exposes `Play next`. In a menu that already has `Next`, `Play
next` reads like a skip action even though it queues the current track again.

## Why

Seek amount is a high-frequency playback setting, so it belongs next to the
playback commands that consume it. Making the amount visible in the transient is
less surprising than overloading prefix arguments, and it keeps the direct
browser bindings predictable.

Removing `Play next` from the current-track transient avoids a label collision
with `Next`. The command remains available as a public command for users who
intentionally want to queue the current track after itself.
