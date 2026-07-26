# Cross-Boundary Contract Gates

## Context

An integration review of the Elisp/helper boundary found that the protocol was
versioned but its consistency was enforced only by release discipline, not by
machinery:

- Elisp pins the exact helper binary version, so schema and protocol numbers
  cannot drift apart in practice, but nothing verified that the git tag,
  `helper/Cargo.toml`, and `ytm-radio--helper-version` agreed. A mismatched
  release would pass checksum verification and then be rejected on every
  command.
- Rust tests asserted the JSON the helper serializes; Elisp tests validated
  hand-built alists. Both suites could stay green while the `data` payload
  shape drifted, because no test moved real helper output across the language
  boundary. The helper's `--mock` mode existed only under `cfg(test)`, so the
  compiled binary could not serve as a deterministic contract fixture.
- Stream resolution was the one helper request with no deadline: reqwest
  bounds YouTube Music HTTP calls and login has an explicit timeout, but a
  stalled yt-dlp subprocess hung the Emacs playback state machine and the
  prefetch queue indefinitely.

## Decision

Make the lockstep and the payload shape machine-checked, and bound the last
unbounded subprocess:

- The release workflow refuses to build when the tag, Cargo manifest, and
  Elisp constant disagree. An ERT test additionally pins the Elisp constant to
  the Cargo manifest so the mismatch fails locally before any release exists.
- Mock data compiles under `any(test, debug_assertions)`. Debug builds accept
  the still-undocumented `--mock` option; release builds reject it. ERT
  contract tests spawn the in-repository debug helper and push its real stdout
  through envelope validation, error parsing, and source normalization.
  `make check` builds the helper before running ERT so these tests execute
  instead of skipping.
- The helper kills yt-dlp after a hard deadline and reports a retryable
  network error, because stream resolution is read-only and a stalled
  extraction is indistinguishable from a stuck network read.

## Why

Exact-version lockstep only guarantees that both sides ship together; it does
not guarantee they agree on field names inside `data`. Spawning the real
binary is a stronger fixture than shared golden files: it also exercises
serialization, argument parsing, exit codes, and the stdout/stderr split, and
it cannot drift independently of the helper the user runs.

Gating mocks on `debug_assertions` rather than shipping them in release
binaries keeps the release surface identical to before; the contract fixture
is a development capability, not a user feature.

## Consequences

Bumping the helper now requires touching Cargo and the Elisp constant
together, or `make check` and the release workflow fail loudly. Renaming a
helper output field fails the Elisp contract tests instead of surfacing as a
runtime rendering bug. A wedged yt-dlp resolves into a structured retryable
error within the deadline instead of a permanent `loading` state.

## Follow-up

External review found two gaps in this change. Killing only the direct
yt-dlp process left descendants holding the output pipes, so the reader
threads could still block past the deadline; yt-dlp now runs in its own Unix
process group, the deadline kills the whole group, and pipe draining is
time-bounded on every platform, with regression tests that spawn
pipe-holding descendants. The release workflow also built whatever ref
triggered it while uploading assets to the requested tag; both jobs now
check out the tag they publish, so the version-consistency gate inspects the
same commit the binaries are built from.

Deliberately deferred: Windows has no process-group kill, so a descendant
spawned by yt-dlp can outlive a timeout there. The helper itself still
cannot block past its deadlines on any platform, the residue is an orphan
process under the user's own account, and full tree cleanup would require
Job Object FFI that this project cannot test because CI only runs helper
tests on Linux. Revisit if a real Windows user base appears or CI gains a
Windows test lane.
