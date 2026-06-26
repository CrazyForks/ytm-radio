# ytm-radio UI Spec

This file records narrow UI contracts that are easy to regress but too detailed
for the PRD.

## Account State Markers

Track rating state comes from the normalized `:like-status` field on ytm-radio
tracks, or from helper item `like-status` values before they are normalized.
When a visible row lacks its own rating state, ytm-radio may reuse a known
rating from another cached row with the same YouTube video id. Saved/library
state (`in-library`) is not a substitute for a thumbs-up rating.

Helper `like-status` fields distinguish unknown state from a known unrated
state. If the helper cannot determine rating state, it omits `like-status`.
If the helper determines that a track is unrated, it returns `like-status:
null`. UI refreshes must preserve cached rating markers when `like-status` is
absent, and clear a cached marker only when the field is present with a null
value.

Track rating markers:

- `like` is rendered as a Material Design thumb-up icon from Nerd Icons:
  `nf-md-thumb_up`.
- `dislike` is rendered as a Material Design thumb-down icon from Nerd Icons:
  `nf-md-thumb_down`.
- If Nerd Icons is unavailable, the fallback glyphs are `▲` for like and `▼`
  for dislike.
- Browser rows and now-playing title rows must not render rating state as the
  words `liked` or `disliked`.
- The rating marker is appended directly after the visible track title with one
  separating space.
- In browser rows, the marker is not part of the title button. It must not carry
  button, action, or follow-link text properties.
- Icon text properties from Nerd Icons, such as the icon face, must be
  preserved on the marker.

Visibility rules:

- Home, Explore, Search, Library Songs, Library Albums/Artists/Playlists where
  track rows appear, detail track lists, queue rows, and now-playing should show
  rating markers when `:like-status` is known on that row or another cached row
  for the same video id.
- Liked Music itself does not show a like marker on every row, because the view
  already communicates that all tracks are liked.
- Library album and playlist bookmark markers remain hidden inside Library
  views to avoid redundant saved-state markers.

Action labels and messages may use words such as `liked`, `disliked`, `Like`,
and `Dislike`; this icon contract applies only to persistent row/title rating
markers.

## Detail Account Mutations

Detail library and subscription mutations return refreshed detail sources from
the already-fetched detail response plus the requested target account state.
After YouTube Music accepts the mutation request, the helper must not wait for a
second detail fetch to verify eventual consistency.

When a detail header is synthesized from an opener item, positive account state
from either the helper source or the opener item is preserved. A saved album or
playlist card must therefore enter a detail page with a saved bookmark marker
even if the helper detail header does not expose reliable library state.

After a detail library or subscription mutation succeeds, the returned target
state must be written back to matching cached opener/list items by browse id or
playlist id. Going back to Home, Explore, or Library should show the same saved
or subscribed marker state that the detail header shows after the mutation.

Detail header bodies are not enterable sections. Pressing `RET` on ordinary
header text must not open a new view that only contains the same header image
and account action; `RET` on real text buttons still runs that button.

## Playback

Selecting a song from the browser with `RET` must start playback immediately.
When ytm-radio reuses an existing mpv IPC process and sends `loadfile`, it must
also clear mpv's pause state so a previously paused player does not leave the
newly selected song loaded but silent.

## Home Continuation

Home continuation tokens are durable state. Cached Home sections without a
known continuation state come from older state files and should trigger one
fresh Home load so lazy loading can recover the next-page token.

## Helper Network Requests

The Rust helper owns YouTube Music HTTP requests. A YouTubeI request that fails
before any HTTP response is received is treated as a transient send failure and
retried twice with short backoff. HTTP error responses are not retried because
they may represent account, auth, or request-shape problems.

When send failures still exhaust all attempts, the helper error must include
the underlying error source chain and the attempt count so the Emacs message can
distinguish DNS, proxy, TLS, timeout, and connection failures.
