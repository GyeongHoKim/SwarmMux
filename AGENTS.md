# AGENTS.md

Instructions for AI coding agents working in this repository.

## What this project is

SwarmMux is a Go SDK for embedding a WebTorrent tracker inside another application. It is a
library, never a daemon: it owns the tracker control plane and exposes a named extension
point for every policy decision it leaves to the caller.

`docs/` is the specification and was written before the implementation. When code and docs
disagree, the docs are the intent — fix the code, or change both in the same commit. Never
let them drift silently.

Read [`docs/architecture.md`](docs/architecture.md) before touching the engine, and
[`docs/extension-points.md`](docs/extension-points.md) before touching `Store`, `Router`,
`Selector`, `Authorizer`, `Metadata`, or `Observer`. Those interfaces carry written
contracts; changing an implementation without re-reading its contract is how they get
violated.

## Quality gate

Run this after every change that touches Go code, and before reporting work as done:

```bash
just format
just lint
just test
```

`just ci` runs the whole gate — the same checks CI runs, in the same order. Prefer it
before handing work back.

Rules:

- Never report a task complete while any gate step fails.
- If a failure is unrelated to your change, say so explicitly rather than leaving it red
  without comment.
- Do not weaken `.golangci.yml`, add `//nolint`, or skip a test to make the gate pass. Fix
  the code. If a lint rule is genuinely wrong here, raise it instead of suppressing it.
- `just test` must stay green on Go 1.24, the minimum version the SDK promises.

## Go style

Follow the [Uber Go Style Guide](https://github.com/uber-go/guide/blob/master/style.md) and
[Effective Go](https://go.dev/doc/effective_go). The rules that come up most in this
codebase:

**API shape**

- Accept interfaces, return concrete types.
- Assert interface compliance at compile time: `var _ Store = (*memoryStore)(nil)`.
- `context.Context` is the first parameter, never stored in a struct.
- Keep the zero value useful. `var tracker Tracker` must work; this is a documented
  guarantee, not an accident.
- Do not embed types in exported structs — it leaks methods into the public API forever.
- Use field names in struct literals.

**Errors**

- Sentinel errors are declared in one place and wrapped with `%w`. Callers use
  `errors.Is` / `errors.As`.
- Error strings are lowercase and unpunctuated: `"peer not found"`, not
  `"Peer not found."`.
- Never `panic` in library code. Return an error.
- Handle failed type assertions with the two-value form.

**Concurrency**

- Every goroutine must have a documented exit path. No goroutine outlives the context that
  spawned it.
- Zero-value `sync.Mutex` is valid; do not embed a mutex in an exported struct.
- Channel size is zero or one. Anything larger needs a reason in the code review, not a
  comment.
- Copy slices and maps at API boundaries — callers must not be able to mutate internal
  state through a returned value.

**Naming and docs**

- Every exported identifier has a doc comment starting with its own name.
- Consistent initialisms: `PeerID`, `InfoHash`, `URL`, not `PeerId` or `Url`.
- Getters have no `Get` prefix.
- Reduce nesting; return early instead of trailing `else`.

## Comments

Comments describe what the code does. No tutorial prose, no background on how a
third-party tool behaves, no multi-paragraph rationale blocks — these files are committed
and read by everyone who clones the repo.

Reasoning that has lasting value goes in `docs/`. Reasoning that only matters right now
goes in the pull request description or the chat, not the file.

## Dependencies

Use a proven library with real production use rather than hand-rolling, and ask before
adding one. A new dependency is the maintainer's call, not yours.

SwarmMux ships the in-memory defaults here and a Redis `Store` and `Router` in a companion
module with its own `go.mod`. Backend adapters do not belong in this module.

Node is present only to run commitlint in the git hooks. It is never a dependency of the
library.

## Tooling

Tool versions are pinned in `mise.toml`; run `mise install` rather than installing tools
another way, so your linter matches CI's exactly. Commands live in the `justfile` — add
new ones there instead of documenting ad-hoc shell invocations.

## Commits

[Conventional Commits](https://www.conventionalcommits.org/), enforced by the `commit-msg`
hook and re-checked on every pull request. The type is not cosmetic: release-please derives
the next version from it.

```text
feat(ws): add overflow policy option
fix: release peer binding on stopped event
docs(architecture): correct the shutdown ordering
```

A `!` after the type or scope marks a breaking change. Subject lines are capped at 72
characters.

Do not commit or push unless asked to.

## Before you finish

- [ ] `just ci` passes
- [ ] Exported identifiers have doc comments
- [ ] `docs/` matches the behavior you implemented
- [ ] Backend adapters stayed in the companion module, not this one
- [ ] No suppressed lint rules or skipped tests
