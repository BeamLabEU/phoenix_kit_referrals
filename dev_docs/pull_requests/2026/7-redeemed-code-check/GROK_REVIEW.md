# PR #7 Review — Redeemed-code check for core's access gate

- **PR:** https://github.com/BeamLabEU/phoenix_kit_referrals/pull/7
- **Merge commit:** `f97d725` (Answer whether a user ever redeemed a code, for core's access gate)
- **Author:** mdon
- **Reviewer:** Grok, via `pr-review-release`
- **Date:** 2026-08-14
- **Scope:** Adds `signup_use_exists?/1` (module facade) and
  `ReferralCodeUsage.exists_for_user?/1` so core's invite-only access gate can
  lazily stamp accounts that redeemed under referrals 0.4 (usage row, no
  `referral_satisfied_at`). Also committed a `.DS_Store`.

## Summary

The new predicate is the right answer to a real production hole: the 0.4 flows
wrote a usage row and nothing else, 0.6's gate trusted only the satisfied-stamp,
and the upgrade parked exactly the people who already did what invite-only asked.
Core dispatches `:signup_use_exists?` through the module registry, stamps on
`true`, and treats a missing export / raise as "cannot confirm, do not admit" —
so the name and the fail-closed contract are load-bearing.

The query itself is sound (usage table is an immutable audit trail; `used_by_uuid`
is indexed in core V135). What was missing is everything around it: tests, docs
on the public surface, a changelog entry, and the macOS junk file. Fixed on
`main`.

## Findings

### BUG - MEDIUM — `.DS_Store` committed *(fixed)*

The merge added a 6 KB Finder file at the repo root. It has no business in git
and `.gitignore` did not mention it, so it would come back.

**Fix:** `git rm` the file and ignore `.DS_Store`. Also corrected the Hex
tarball ignore from the leftover `phoenix_kit_hello_world-*.tar` template name
to `phoenix_kit_referrals-*.tar`.

### IMPROVEMENT - HIGH — No tests for the core-facing predicate *(fixed, as far as this suite can)*

Neither function was mentioned in the test suite. A rename of
`signup_use_exists?/1` is a silent production outage: core's
`historically_redeemed?/1` does `dispatch(:signup_use_exists?, [user.uuid])`,
and a missing export is `:error`, which the gate reads as "do not admit".

This package has no TestRepo (see `mix.exs` — the suite is pure-unit on
purpose). A DB-backed "user with a usage row → true" case would mean standing
up the hello-world DataCase template, which is a bigger change than this PR.

**Fix:** added tests that lock what we *can* lock without a database:

- the exact exported name and arity core dispatches
- a non-UUID binary returns `false` (does not raise / hit the repo)
- `nil` raises `FunctionClauseError`

The happy-path query is covered on the core side
(`phoenix_kit/test/phoenix_kit/users/referral_access_gate_test.exs`) against a
stub module; that is the right place for the gate's control flow.

### IMPROVEMENT - MEDIUM — Invalid UUID would raise into core's rescue *(fixed)*

`used_by_uuid` is a `UUIDv7` column. Passing a non-UUID binary through
`exists?` is a cast error. Core's `dispatch/2` rescues that, logs a warning,
and fail-closes — so it would not admit anyone — but a `?` function used as
an access-gate predicate should not 500-and-rescue on junk input.

**Fix:** `exists_for_user?/1` now returns `false` unless
`PhoenixKit.Utils.UUID.valid?/1`. The facade stays a one-line delegate.

### IMPROVEMENT - MEDIUM — Public surface was incomplete *(fixed)*

`signup_use_exists?/1` was not listed under Usage Tracking in the module
moduledoc, the CHANGELOG's `[Unreleased]` section was empty and sitting
*below* 0.6.1, and the README still advertised `phoenix_kit ~> 1.7` plus
**Admin → Users → Referrals** (the nav has been its own top-level section
since 0.4.0).

**Fix:** documented the function, restored Keep-a-Changelog order with an
Unreleased entry, and corrected the README pin and nav path. Also rewrote the
stale `access_gate_available?/0` doc that still talked about a `~> 1.7` pin.

### NITPICK — `exists_for_user?/1` reimplemented `for_user/1` *(fixed)*

The new query was `where: used_by_uuid == ^user_uuid, limit: 1`, which is
`for_user/1` plus a redundant `limit` (`Repo.exists?/2` already applies
`LIMIT 1` and strips `order_by`). Now it is
`repo().exists?(for_user(user_uuid))`, so the filter lives in one place.

### NITPICK — Name is awkward *(not fixed)*

`signup_use_exists?` reads as "signup-use exists" rather than "this user
redeemed a code". `has_redeemed_code?` would be nicer. **Do not rename:**
core already dispatches this atom. A rename here parks every 0.4-era
redeemer until core is updated in lockstep.

## Verified, no change needed

- **Semantics are right.** Usage rows are never deleted when a code expires
  or is revoked, so "any row for this user" is "ever redeemed".
- **Index exists.** `phoenix_kit_referral_code_usage_used_by_uuid_idx` is in
  core V135; the query is an index lookup.
- **Guard is present.** `when is_binary(user_uuid)` matches `use_code/2` /
  `user_used_code?/2`.
- **No migration.** Correct — the data is already there; only the query was
  missing. Hosts are repaired whenever they upgrade, in either order.
- **Delegation pattern** matches `user_used_code?/2` / `get_usage_stats/1`.

## Version / release

Left at `0.6.1`. This is a new public function plus a production-facing
contract with core; the Hex release should be at least `0.6.2` (Unreleased
entry is ready to retitle). Not bumped in this review commit so the version
bump can be its own "Bump version to …" commit per the release checklist.

## Gate

`mix format`, `mix test` (31 tests, 0 failures), then `mix precommit`
(compile `--warnings-as-errors` + `deps.unlock --check-unused` +
`hex.audit` + `format --check-formatted` + `credo --strict` +
`dialyzer`) — clean.
