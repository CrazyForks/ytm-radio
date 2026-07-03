# Authenticated Account Playback

## Context

The account helper could browse and normalize Music Premium tracks because it
used the browser-login session in `auth.json`. Playback still sent each watch
URL to mpv's unauthenticated yt-dlp hook. Premium-only tracks therefore failed
even though they were visible in Library.

Configuring `cookies-from-browser` was not a valid product fix. yt-dlp supports
a different browser set from the login helper, does not recognize Dia directly,
and may be blocked from browser profiles by operating-system privacy controls.
It also duplicated the browser-specific authentication path that the helper was
created to own.

## Decision

Helper-backed tracks are marked as account tracks. Before mpv starts, the Rust
helper resolves those tracks with the existing `auth.json` session and returns
a direct audio URL. The same command is used for immediate playback, next-track
prefetch, and the single automatic retry after a failed direct stream.

yt-dlp requires Netscape cookie input. For one resolution, the helper converts
the auth cookie header into a uniquely created `0600` temporary file, invokes
yt-dlp, and removes the file before exiting. Cookie contents never enter Emacs,
mpv arguments, helper stdout, or the process command line. The durable session
remains only in `auth.json`.

Transient URLs imported outside the account browser keep the existing public
yt-dlp and mpv compatibility path. They are not silently upgraded to account
playback.

## Why

All supported login browsers already converge on the same validated auth
schema. Reusing that schema makes playback independent of browser cookie
databases and keeps account access in the helper boundary. Returning a direct
URL also lets the existing in-memory stream cache and mpv transport remain
unchanged.

The temporary file is a compatibility adapter for yt-dlp, not a second session
store. Private creation and deterministic cleanup limit exposure while avoiding
Cookie headers in observable process arguments.

## Limitation

Authenticated playback depends on mpv fetching the resolved direct URL. The
current direct transport supports no proxy or an HTTP/HTTPS proxy; SOCKS-only
routing remains unsupported for helper-backed account tracks.
