# Account State and Helper Ownership

## Context

Account state appeared in normalized tracks, raw helper items, detail sources,
the opener context, and the current player track. Mutations copied values into
all matching objects by scanning every cached source. That made Home, detail,
and now-playing dependent on whether a particular copy had been updated.

Elisp also classified helper failures by matching English diagnostics and
deleted cache paths whose layout belonged to the Rust helper. Both behaviors
made internal helper changes part of the Elisp contract.

## Decision

Elisp keeps one ephemeral account-state index keyed by stable video, browse,
playlist, or channel ids. Cached source payloads seed the index but remain
unchanged; successful mutations override indexed state directly.

The helper emits structured error metadata on stdout for failures. It also owns
response-cache bypass and invalidation: explicit refresh uses `--fresh`, account
mutations invalidate response caches, and login invalidates all auth-adjacent
caches.

Only read requests retry transient send failures. Mutations are sent once
because a lost response does not prove that YouTube Music failed to apply the
request.

## Consequences

Rendering no longer performs global scans or relies on mutable duplicate
payloads. Helper diagnostics and cache directory names can change without
changing Elisp behavior. The runtime index is intentionally not durable;
persisted helper sources seed it again when Emacs starts, and a fresh account
request remains authoritative.
