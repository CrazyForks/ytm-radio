# Helper Boundary And Diagnostics

## Context

ytm-radio needs account-scoped YouTube Music requests, browser login import,
and enough diagnostics to explain setup failures. Dynamic modules and resident
services were considered because they can look more integrated from Emacs.

## Decision

Keep account access in the short-lived Rust CLI helper. Do not add an Emacs
dynamic module or a resident helper service for the current product shape.

Add low-complexity improvements around that boundary:

- cache non-secret YouTube Music bootstrap data beside the auth file;
- keep timing diagnostics opt-in through stderr;
- add an Emacs `ytm-radio-doctor` report for executable and auth setup.

## Why

The current latency is dominated by YouTube Music network requests, bootstrap
fetches, image downloads, and media extraction, not by Rust process startup or
JSON decoding. A dynamic module would optimize the wrong layer before profiling
shows local call overhead is material.

A CLI helper is also a safer failure boundary. Helper crashes, malformed
responses, and auth import failures can be reported without crashing Emacs.
Users and maintainers can run the helper directly, inspect stderr diagnostics,
and validate setup from `M-x ytm-radio-doctor`.

Dynamic modules raise the installation bar: users need Emacs module support,
platform-specific shared libraries, ABI compatibility, and macOS signing or
quarantine handling. A standalone helper still needs to be built or installed,
but that path can later be improved with prebuilt binaries or package-manager
recipes without changing the Emacs protocol.

## Follow-up

Reconsider a dynamic module only if profiling shows that local process startup
and JSON decoding dominate real interactive latency after caching, async loading,
and image handling are already optimized.
