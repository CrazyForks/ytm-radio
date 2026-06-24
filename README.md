# ytm-radio

An experimental Emacs audio player for YouTube and YouTube Music.

The design follows the useful part of `ytr`: `yt-dlp` discovers URL metadata,
and `mpv` plays audio with video disabled. Emacs owns the catalog, playback
state, selection commands, and UI.

YouTube Music account access is a separate Rust CLI. It is not an Emacs
dynamic module and does not run as a resident service. Emacs starts one
process for a request, reads a versioned JSON response, and the process exits.

## Status

Implemented:

- add YouTube and YouTube Music URLs through `yt-dlp`;
- normalize playlists, channels, and tracks into a local catalog;
- play through `mpv --no-video`;
- pause, next, previous, stop, and seek through mpv IPC;
- show YouTube Music browse pages in a regular buffer;
- show the current cover, playback progress, and controls in a child-frame
  now-playing view;
- invoke an external Rust account helper;
- import Dia login cookies and YouTube Music page context through the browser's
  DevTools protocol;
- import browser cookies through `yt-dlp` into a private helper auth file;
- import copied browser request headers into a private helper auth file;
- make authenticated YouTube Music home, library, liked, and search requests;
- normalize live music renderers into playable tracks;
- preserve non-track YouTube Music items such as albums, artists, playlists,
  and recommendation cards when they are present in browse responses;
- render Home and Library as Emacs-native section dashboards;
- import deterministic mock account data;
- reject unsupported helper JSON schema versions.

Not implemented yet:

- detail pages for every album, artist, playlist, and radio renderer;
- encrypted credential storage;
- local account-data caching;
- full renderer coverage for every YouTube Music web card type.

The live API is an unofficial YouTube Music web protocol and can change without
notice. The helper dynamically reads current client configuration from the
YouTube Music page instead of hardcoding the API key.

## Requirements

- Emacs 29.1 or newer
- `yt-dlp`
- `mpv`
- a Rust toolchain for building the optional account helper

No Python runtime or Python package is used.

## Setup

Build the helper:

```sh
cargo build --manifest-path helper/Cargo.toml
```

Load the Emacs package:

```elisp
(add-to-list 'load-path "/Users/luciuschen/repos/ytm-radio")
(require 'ytm-radio)
```

Opening `M-x ytm-radio` does not prompt for a URL when the catalog is empty.
Use `A` once for login, then `H`, `E`, `L`, `/`, or `a` to browse account
pages, search, or add a URL.

The main `*ytm-radio*` buffer is the YouTube Music browser. It renders Home,
Explore, Library, Search, and URL-backed pages as vertical Emacs sections with
compact track/card rows. Home, Explore, and Library sections preserve YouTube
Music modules such as listen-again, mixed-for-you, albums, playlists, artists,
and liked music when the web response includes them.
Home, Explore, and Library use cached sections first and only load asynchronously
when a view has no cached data or when explicitly refreshed. Home continuation
pages load lazily when the visible Home buffer reaches the rendered end.

The child frame is a ytr-style now-playing surface. It fits itself to the
current cover image, shows title, artist, time, and progress, and exposes the
core playback controls without turning the child frame into the main browser.

The default helper path points to:

```text
helper/target/debug/ytm-radio-helper
```

Set `ytm-radio-helper-command` explicitly when installing the binary
elsewhere:

```elisp
(setq ytm-radio-helper-command
      "/absolute/path/to/ytm-radio-helper")
```

Run `M-x ytm-radio-doctor` when playback, login import, or account browsing
does not start. It reports whether the helper, `mpv`, `yt-dlp`, the runtime
directory, and the auth file are visible from Emacs.

## Commands

- `M-x ytm-radio` opens the YouTube Music browser buffer.
- `M-x ytm-radio-doctor` shows a setup diagnostic report.
- `M-x ytm-radio-home` switches to Home.
- `M-x ytm-radio-explore` switches to Explore.
- `M-x ytm-radio-library` switches to Library.
- `M-x ytm-radio-auth-import` imports a logged-in browser session.
- `M-x ytm-radio-add-url` adds a YouTube or YouTube Music URL.
- `M-x ytm-radio-import-ytmusic-library` imports library sources.
- `M-x ytm-radio-import-ytmusic-home` imports home recommendations.
- `M-x ytm-radio-more` opens hidden items in the current section.
- `M-x ytm-radio-load-more-home` imports the next Home continuation page.
- `M-x ytm-radio-import-ytmusic-explore` imports explore sections.
- `M-x ytm-radio-import-ytmusic-liked` imports liked songs.
- `M-x ytm-radio-refresh` refreshes the current browser view.
- `M-x ytm-radio-search` searches YouTube Music.
- `M-x ytm-radio-now-playing` shows the cover child frame.
- `M-x ytm-radio-play-track` selects a known track.
- `M-x ytm-radio-play-source` selects a known source.
- `M-x ytm-radio-toggle-pause` toggles mpv pause.
- `M-x ytm-radio-cycle-repeat` cycles repeat off, all, and one.
- `M-x ytm-radio-toggle-shuffle` toggles shuffle playback.
- `M-x ytm-radio-stop` stops playback.
- `M-x ytm-radio-next` plays the next track.
- `M-x ytm-radio-previous` plays the previous track.
- `M-x ytm-radio-share` copies the current track URL.
- `M-x ytm-radio-seek-forward` seeks forward.
- `M-x ytm-radio-seek-backward` seeks backward.
- `M-x ytm-radio-hide-browser` hides the browser buffer.
- `M-x ytm-radio-hide-now-playing` hides the now-playing child frame.
- `M-x ytm-radio-hide` hides ytm-radio UI.

Inside the browser buffer:

| Key | Action |
| --- | --- |
| `A` | Import browser login |
| `a` | Add URL |
| `c` | Show cover child frame |
| `H` | Switch to Home |
| `E` | Switch to Explore |
| `L` | Switch to Library |
| `i` | Import liked songs |
| `/` | Search YouTube Music |
| `RET` | Play a track or open the item/source at point |
| `j`, `k`, `Down`, `Up` | Move between item rows |
| `m` | Open more items for the current section |
| `g` | Refresh the current browser view |
| `TAB`, `S-TAB` | Move between sections |
| `b` | Return to the previous browser view |
| `s` | Play source at point, or select a source |
| `SPC` | Toggle pause |
| `n` | Next track |
| `p` | Previous track |
| `S` | Copy current track URL |
| `f` | Seek forward |
| `B` | Seek backward |
| `q` | Hide the browser buffer |

Use `M-x imenu` in Home, Explore, or Library to jump between rendered
sections.

Inside the now-playing child frame:

| Key | Action |
| --- | --- |
| `SPC` | Toggle pause |
| `n` | Next track |
| `p` | Previous track |
| `r` | Cycle repeat mode |
| `s` | Toggle shuffle |
| `S` | Copy current track URL |
| `q` | Hide the child frame |

## Helper Contract

The CLI surface is:

```text
ytm-radio-helper auth check --auth FILE
ytm-radio-helper auth import-dia --output FILE [--port N] [--app PATH] [--restart]
ytm-radio-helper auth import-browser --browser BROWSER --output FILE [--yt-dlp PROGRAM]
ytm-radio-helper auth import-headers --input FILE --output FILE
ytm-radio-helper browse home --auth FILE [--limit N] [--initial-only]
ytm-radio-helper browse home --mock [--limit N] [--initial-only]
ytm-radio-helper browse explore|library|library-songs|library-albums|library-artists|library-playlists|liked --auth FILE [--limit N]
ytm-radio-helper browse explore|library|library-songs|library-albums|library-artists|library-playlists|liked --mock [--limit N]
ytm-radio-helper browse-id BROWSE_ID --auth FILE [--params PARAMS] [--limit N]
ytm-radio-helper browse-id BROWSE_ID --mock [--params PARAMS] [--limit N]
ytm-radio-helper continuation TOKEN --auth FILE [--limit N]
ytm-radio-helper continuation TOKEN --mock [--limit N]
ytm-radio-helper search QUERY --auth FILE [--limit N]
ytm-radio-helper search QUERY --mock [--limit N]
```

For `home`, `explore`, and `library`, the helper preserves YouTube Music
sections and returns each section as a source. `browse home --initial-only`
returns only the first Home page plus a continuation token. `continuation TOKEN`
loads the next Home section page. The limit applies per section.
The explicit library subtargets return focused sources for songs, albums,
artists, playlists, and liked music. `search` returns a source containing mixed
result items.
`browse-id` is used internally by the Emacs UI to expand albums, artists, and
playlists without sending YouTube Music-only pages through yt-dlp. When YouTube
Music returns endpoint `params`, the Emacs UI passes them through `--params`
because some playlist and mix pages reject a bare `browseId`.

Responses use a stable envelope:

```json
{
  "ok": true,
  "schema": 1,
  "data": {
    "sources": []
  },
  "warnings": []
}
```

## Login

Log in to `music.youtube.com` in Dia, Chrome, Firefox, Safari, Edge, Brave, or
another supported browser, then run:

```elisp
M-x ytm-radio-auth-import
```

Choose the browser in the `Login source` prompt. Common choices include
`chrome`, `firefox`, `safari`, `edge`, `brave`, `chrome:Default`, and `dia`.

For yt-dlp supported browsers, the command:

1. asks `yt-dlp` to read the selected browser's cookie store;
2. keeps only YouTube cookies;
3. verifies that an authenticated SAPISID cookie exists;
4. writes a private JSON file with mode `0600` on Unix;
5. configures `ytm-radio-helper-auth-file`.

For Dia, the same command dispatches internally to the Dia DevTools path. The
helper reads the YouTube Music page's `ytcfg` session context in addition to
cookies, so Home, Library, and brand-account requests use the same account
identity as the web page. If Dia is already running without the DevTools
endpoint, Emacs asks whether it may restart Dia once and then retries.

The default output is:

```text
~/.ytm-radio/auth.json
```

Runtime data defaults to `~/.ytm-radio/`: `auth.json` stores the helper session,
`bootstrap-cache.json` stores non-secret YouTube Music client bootstrap data,
`state.eld` stores imported sources and the last track, and `covers/` caches
cover images. The helper refreshes `bootstrap-cache.json` automatically when it
is missing, invalid, or older than 12 hours. If default
`~/.emacs.d/ytm-radio/auth.json` or `state.eld` files already exist from an
older checkout, ytm-radio copies them into the new directory on first startup.

Browser or macOS Keychain permission prompts may appear during import. Close
the browser first if its cookie database is locked.

Set a preferred browser when needed:

```elisp
(setq ytm-radio-helper-browser "firefox")
```

Dia's default executable is:

```text
/Applications/Dia.app/Contents/MacOS/Dia
```

Customize it when needed:

```elisp
(setq ytm-radio-helper-dia-app
      "/Applications/Dia.app/Contents/MacOS/Dia")
```

The default local DevTools port is `29317`:

```elisp
(setq ytm-radio-helper-dia-cdp-port 29317)
```

## Header Fallback

`M-x ytm-radio-auth-import-headers` remains available as a debugging fallback
if browser import fails:

1. Open `https://music.youtube.com` in Dia while logged in.
2. Open DevTools, then the Network tab.
3. Reload the page or click a library/home item.
4. Select a `browse` request to `music.youtube.com/youtubei/v1/browse`.
5. Copy the request headers into a local text file. The file must include the
   `cookie` header; `user-agent`, `x-goog-authuser`, `x-goog-pageid`,
   `x-origin`, and `referer` are also used when present.
6. Run `M-x ytm-radio-auth-import-headers` and pick that file.

The request header file contains account session material. Delete it after
importing, and keep the generated auth JSON out of git.

For deterministic local testing without account access:

```elisp
(setq ytm-radio-helper-use-mock-data t)
```

Then run one of the account import commands. Mock mode does not require an auth
file.

The default file is reused automatically in future Emacs sessions. For a
custom location:

```elisp
(setq ytm-radio-helper-auth-file
      "~/.ytm-radio/browser-headers.json")
```

The auth file may contain account session material. Keep it out of git and
never store its contents in Emacs state.

Set `YTM_RADIO_TIMINGS=1` before starting Emacs to make the Rust helper print
bootstrap and YouTube Music request timings to stderr. Successful helper stdout
remains machine-readable JSON.

## Protocol References

- [yt-dlp browser cookie extraction](https://github.com/yt-dlp/yt-dlp#filesystem-options)
- [ytmusicapi browser authentication](https://github.com/sigma67/ytmusicapi/blob/master/ytmusicapi/auth/browser.py)
- [ytmusicapi browsing requests](https://github.com/sigma67/ytmusicapi/blob/master/ytmusicapi/mixins/browsing.py)

## URL Cookies

Configure discovery-time `yt-dlp` options:

```elisp
(setq ytm-radio-yt-dlp-extra-args
      '("--cookies-from-browser" "chrome"))
```

Configure mpv's ytdl hook:

```elisp
(setq ytm-radio-ytdl-raw-options
      '("cookies-from-browser=chrome"))
```

ytm-radio enables a conservative mpv network cache by default for long YouTube
Music tracks:

```elisp
(setq ytm-radio-mpv-network-cache-args
      '("--cache=yes"
        "--demuxer-readahead-secs=60"
        "--demuxer-max-bytes=256MiB"))
```

Set `ytm-radio-mpv-extra-args` to override these values when needed. Extra args
are passed after the default cache args, so mpv's later option wins.

## Development

Run all deterministic checks:

```sh
make check
```

This byte-compiles Elisp, runs ERT, checkdoc, package-lint, Rust formatting,
Clippy, and unit tests.
