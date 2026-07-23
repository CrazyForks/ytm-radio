# Firefox-Family Isolated Login Profiles

## Context

Firefox and Zen originally used their normal browser profile for WebDriver BiDi
login unless the user configured an explicit profile directory. Starting
Firefox Remote Agent against a normal profile can apply automation preferences
to that profile. In the observed failure, `focusmanager.testmode` remained
enabled after login and prevented Fcitx5 input from committing text into normal
Firefox fields.

Leaving the automated browser open after auth import also extended those
automation settings into ordinary browsing. Restoring individual preferences
after login would remain vulnerable to helper failures, browser crashes, and
future changes to Firefox's recommended automation preferences.

An empty isolated profile introduced a second constraint: Google rejected
credential entry inside the WebDriver-controlled Firefox window. Hiding
automation would be fragile, while copying cookies from the normal profile
would cross the established browser-login boundary.

## Decision

Firefox and Zen now receive helper-managed isolated profiles by default, just
as Chrome already receives an automatic profile for its DevTools login flow.
The profiles live next to the auth file as `login-profile-firefox` and
`login-profile-zen`. An explicit
`ytm-radio-helper-login-profile-directory` continues to override the automatic
selection.

The login helper starts Firefox-family isolated profiles with `--no-remote`,
imports the session into the dedicated auth file, and closes the spawned login
browser afterward. Normal Firefox and Zen profiles are never used by the
default automated login path.

`ytm-radio-prepare-login` provides an explicit one-time preparation path. The
helper opens the isolated profile without a remote-control endpoint and waits
for the user to sign in and close it. Emacs then starts the existing BiDi login
window to import the prepared session. This workflow has no hidden marker or
browser-detection heuristic.

## Consequences

Users sign in once inside the isolated login profile instead of reusing an
existing normal-profile session. The isolated profile preserves its own login
state for later auth renewal while keeping Remote Agent preferences out of
normal browsing.

Preparation is a separate explicit command because only the user can complete
Google sign-in in the ordinary browser window. It needs to be repeated only
when that isolated profile loses its Google session.

This decision supersedes the normal-profile default described in the Firefox,
Chrome-profile, and Zen login postmortems. Other browser defaults and explicit
profile overrides remain unchanged.
