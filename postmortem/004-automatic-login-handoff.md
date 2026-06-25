# Automatic Login Handoff

## Context

The browser login window replaced several fallback auth paths, but the Emacs UX
still required users to know about `M-x ytm-radio-login` before the main
browser could show account-backed content. That leaked setup mechanics into the
primary entry point: opening `M-x ytm-radio` with no auth produced an empty
catalog instead of guiding the user into the account flow.

Auth failure after an existing import had a similar problem. A stale auth file
or old auth source surfaced as a helper error, even though the next useful
action was the same browser login flow.

## Decision

Treat login as an internal account-access handoff:

- account-backed Home, Explore, Library, Search, continuation, and detail
  requests run through one Elisp account wrapper;
- missing auth starts the browser login flow automatically;
- login success resumes the action that required account access;
- HTTP 401/403, missing credential, old auth-source, and invalid auth-file
  diagnostics clear account-derived state and enter the same login flow;
- `M-x ytm-radio-login` remains available as a manual refresh command, not as a
  required first step.

## Why

The main product entry point should be `M-x ytm-radio`, not a setup command.
The user intent is to browse or play music; needing account material is an
implementation detail that ytm-radio can handle once the user reaches an
account-backed view.

Retrying the original action after login also prevents context loss. If the
user searched, opened Explore, or selected an artist page, the app should
continue that action instead of always dropping them onto Home.

The implementation stays in Elisp because it coordinates UI state and helper
processes. The Rust helper still owns the browser and YouTube Music protocol
work; Emacs only decides when to invoke it.

## Follow-up

If login failures become noisy, add a small in-buffer status line for active
login instead of relying only on minibuffer messages. Do not add alternate auth
fallbacks unless a concrete browser failure requires a new product decision.
