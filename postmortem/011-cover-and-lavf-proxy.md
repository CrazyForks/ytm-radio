# Login, Cover, And Lavf Proxy Routing

## Context

GitHub issue #2 reported that a user who configures only
`ytm-radio-proxy-url` still had to configure Emacs `url-proxy-services` for
cover images, a Chromium `--proxy-server` argument for the login window, and an
mpv lavf option for direct media URL downloads.

## Decision

HTTP and HTTPS `ytm-radio-proxy-url` values now also drive Emacs cover image
downloads by dynamically binding `url-proxy-services` around `url-retrieve`.

The login-window workflow now accepts the same proxy setting. ytm-radio passes
it to `auth login-window`, and the helper applies it when it launches a
Chromium-compatible CDP browser by adding `--proxy-server=...`. This is limited
to the browser process that ytm-radio starts. Already-running browser sessions
keep their existing network configuration. Firefox-family WebDriver BiDi login
also uses browser or system proxy settings; ytm-radio deliberately does not
rewrite Firefox or Zen profile preferences for login.

For mpv direct media URL playback, ytm-radio keeps passing `--http-proxy` and
also passes `--stream-lavf-o-append=http_proxy=...`. The ytdl hook still
receives the proxy through `--ytdl-raw-options`, and non-HTTP proxies keep the
existing direct-stream-cache avoidance behavior.

## Consequences

Users with a local proxy can rely on one ytm-radio setting for helper requests,
yt-dlp discovery, Chromium login launches, cover downloads, and mpv playback
paths. Users who log in through Firefox, Zen, or an already-running browser
still need that browser to have working proxy configuration.
