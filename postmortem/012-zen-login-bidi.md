# Zen Login Through WebDriver BiDi

## Context

Zen is built on Firefox and exposes the same in-process WebDriver BiDi endpoint
used by the existing Firefox login path. Treating an explicitly configured Zen
executable as an unknown Chromium browser would launch it with CDP assumptions
and fail before account cookies could be collected.

## Decision

The helper now recognizes Zen's platform executable names and routes Zen
through the existing BiDi implementation. macOS discovery uses the packaged
`Zen.app/Contents/MacOS/zen` path. Linux discovery supports the `zen` and
`zen-browser` commands, while explicit paths also recognize official
`zen-*.AppImage` files.

BiDi session creation no longer requests `browserName: firefox`. Zen reports
its own application name, and the helper has already selected the executable
before connecting to the local endpoint, so an empty capability request is the
correct protocol-neutral negotiation. Cookie extraction, page-context capture,
auth-file storage, profile handling, and restart behavior remain shared with
Firefox rather than introducing a Zen-specific authentication path.

## Consequences

Zen gains the Firefox-family login path without a separate cookie importer or
browser-specific session format. Its login window retains the same operational
constraint as Firefox: the browser or system configuration owns proxy routing,
and a running process without the BiDi endpoint cannot be attached retroactively.
