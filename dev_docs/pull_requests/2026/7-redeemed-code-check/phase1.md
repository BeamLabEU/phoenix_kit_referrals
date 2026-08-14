# PR #7 Phase 1 Review — phoenix_kit_referrals
**Title:** Answer whether a user ever redeemed a code, for core's access gate
**Author:** Max Don (mdon)
**Date:** 2026-08-14
**Verdict:** REQUEST CHANGES

## Summary

Adds `signup_use_exists?/1` (facade) and `ReferralCodeUsage.exists_for_user?/1`
(internal) to answer whether a user has ever redeemed any referral code. The
motivation is a real production bug: accounts that redeemed under referrals 0.4
have a usage row but no `referral_satisfied_at` stamp (the stamp arrived in 0.6),
so core 2.x's access gate was blocking exactly the users who completed the
invite-only requirement. Core calls this lazily through the module registry and
stamps on a hit, so each account pays the query at most once.

The core logic is correct and the query is properly indexed. Two blockers must be
resolved before merge: missing tests and no version bump. A committed `.DS_Store`
needs cleanup as well.

## Findings

### Blockers

**B1 — No tests for the new public API**
`signup_use_exists?/1` and `ReferralCodeUsage.exists_for_user?/1` are completely
uncovered. The test file (`phoenix_kit_referrals_test.exs`) has no mention of
either function. For an integration point that core's access gate will call in
production to make access decisions, this is unacceptable. Minimum required:
- user with a usage row → returns `true`
- user with no usage rows → returns `false`
- edge: user who used a code that is now expired/revoked → should still return
  `true` (this is "ever redeemed", not "currently holding a valid code")

**B2 — No version bump**
The PR description explicitly notes "No CHANGELOG, no `@version`." Current
version is `0.6.1`. Adding a new public API function requires at minimum a patch
bump to `0.6.2` before release to Hex. Per semver this is arguably `0.7.0`
(new public function), but a patch is defensible given the narrow scope. Either
way it must be resolved before publishing.

### Non-blockers

**N1 — `.DS_Store` committed**
The diff includes `diff --git a/.DS_Store b/.DS_Store`. A macOS artifact has no
place in the repo. It also needs to be added to `.gitignore` — the current
`.gitignore` has no `.DS_Store` entry, so this will recur.

**N2 — CHANGELOG not updated**
Follows from B2, but worth calling out separately: the `## 0.6.1` block at the
top of `CHANGELOG.md` has no entry for this change. A new entry (under
`[Unreleased]` or the new version header) describing the new function should be
added alongside the version bump.

### Nitpicks

- The function name `signup_use_exists?` reads a little oddly — it parses as
  "signup-use exists" rather than "signup used a referral". `redeemed_any_code?`
  or `has_redeemed_code?` would be more idiomatic. That said, if core already
  depends on this name in an open PR, changing it now creates churn. Noted for
  awareness only.

- The `limit: 1` in the query is technically redundant since `Repo.exists?`
  already optimises with `LIMIT 1` at the SQL level, but it's consistent with
  the existing `user_used_code?/1` pattern in the same module, so it's fine.

## What is correct (for the record)

- **Semantics are right.** The usage table is an immutable audit trail — rows
  are never deleted when a code expires or is revoked — so querying it for
  "ever redeemed" is correct. Expired/revoked codes still count.
- **Index exists.** `phoenix_kit_referral_code_usage_used_by_uuid_idx` on
  `used_by_uuid` is present in V135 (line 3378), so the query hits an index.
  No seq-scan risk.
- **Guard clause present.** `when is_binary(user_uuid)` protects against nil
  callers.
- **Delegation pattern is clean.** Facade → internal module follows the existing
  convention throughout this library.
- **No migration needed.** Correct — the data already exists in the usage table;
  the only missing piece was the query.

## Stats
- Additions: 26 lines
- Deletions: 0 lines
- Changed files: 3 (`phoenix_kit_referrals.ex`, `referral_code_usage.ex`, `.DS_Store`)
- Tests: 0 added (existing suite: 0 coverage of new functions)
- Migrations: none (appropriate)
- Version bump: none (needed before Hex publish)
- Dependency changes: none
- CHANGELOG: not updated
