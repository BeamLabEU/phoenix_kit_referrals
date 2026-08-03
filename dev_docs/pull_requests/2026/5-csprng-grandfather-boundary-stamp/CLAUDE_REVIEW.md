# PR #5 Review — CSPRNG codes, grandfathering toggle, invite-only boundary stamp

- **PR:** https://github.com/BeamLabEU/phoenix_kit_referrals/pull/5
- **Merge commit:** `d6f9cd1` (Merge pull request #5 from mdon/main)
- **Author:** mdon
- **Reviewer:** Claude (Opus 5), via `pr-review-release`
- **Date:** 2026-08-03
- **Scope:** Three commits — `0f9e2d9` swaps `generate_random_code/0` from
  `Enum.random/1` to `:crypto.strong_rand_bytes/1` and adds a compile-time
  alphabet-bias guard; `ed121b8` adds a `referral_grandfather_existing` setting
  plus an admin toggle; `f34b9f3` makes `set_required/1` eagerly stamp
  `referral_required_enabled_at`.

## Summary

The CSPRNG commit is the good one — correct, well-reasoned, and the
compile-time guard plus distribution test are the right way to keep the
`rem/2` mapping honest. It needed no changes.

The other two commits are written against `PhoenixKit.Users.Referrals` as it
exists in the **local, unpublished** core checkout. Two things follow from
that, and both are real:

1. The eager boundary stamp duplicates something core already does — and does
   *better*. Core stamps the flip time and refuses to move an existing
   boundary; the PR's version stamps `now` unconditionally, which hands an
   attacker-free amnesty to every account created during the current
   invite-only period if `set_required(true)` is ever called twice. Removed.
2. On every **published** core (including the current latest, 1.7.226) there
   is no access gate at all, so the grandfather toggle was a switch wired to
   nothing while promising, in its own label, that flipping it off would park
   existing users. Now capability-gated.

Findings below. Fixes applied on `main`; gate is green.

## Findings

### BUG - HIGH — Eager boundary stamp resets the grandfather boundary, admitting everyone signed up under invite-only *(fixed)*

`lib/phoenix_kit_referrals.ex`, before:

```elixir
def set_required(required) when is_boolean(required) do
  result = Settings.update_boolean_setting_with_module(...)
  with {:ok, _} <- result, do: stamp_required_boundary(required)
  result
end

defp stamp_required_boundary(true) do
  Settings.update_setting(
    "referral_required_enabled_at",
    DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
  )
end
```

Core owns this setting and syncs it from `access_required?/0`:

```elixir
defp sync_required_since(true) do
  if is_nil(required_since()) do
    stamp(@required_since_setting, DateTime.to_iso8601(fallback_boundary()))
  end
  :ok
end
```

Note the `if is_nil(...)`. Core stamps the boundary **once per invite-only
period and never moves it**. The PR's version has no such guard, so any
`set_required(true)` on an install that is *already* invite-only rewrites the
boundary to `now`. Every account created between the original flip and that
call then satisfies `grandfathered?/1` and is admitted with no code — the exact
condition the gate exists to prevent.

**Failure scenario.** Two admins have the settings page open. Admin A flips
invite-only on at 09:00. Admin B's LiveView still holds
`referral_codes_required: false` in its assigns (it was mounted before, and
nothing broadcasts the change), so when B clicks the toggle at 15:00,
`new_required = !false = true` and `set_required(true)` runs a second time. The
boundary jumps from 09:00 to 15:00, and the six hours of signups that were
supposed to be behind the gate are silently grandfathered. B's UI reports
"Referrals are now required" while having done the opposite.

The stated justification for stamping eagerly does not hold either. The PR
comment says core "stamps this lazily too, on the first gated request after the
flip — but 'first gated request' can be a long time after 'flip' on a quiet
site". That window is precisely what core's `fallback_boundary/0` already
closes, and core says so in its own comment:

> When core has to stamp the boundary itself, "now" is the wrong answer: this
> runs on the first GATED REQUEST after the flip, not at the flip […] The
> `referral_codes_required` row's own `date_updated` is when the switch was
> actually thrown, so use it.

So core's lazy stamp resolves to the *flip time* regardless of how late it
runs. The eager stamp buys nothing and costs the `is_nil` guard. Core is also
explicit that it wants to be the only writer:

> Core stamps and clears that setting itself, from `access_required?/0`, rather
> than relying on the referrals admin toggle — that way it stays correct
> whoever flips the switch, including an older `phoenix_kit_referrals` that
> knows nothing about the gate.

**Fix:** `stamp_required_boundary/1` removed and `set_required/1` restored to
returning the settings write directly. One writer, no drift, no reset.

### BUG - MEDIUM — Grandfather toggle claimed enforcement that no published core performs *(fixed)*

`mix.exs` pins `pk_dep(:phoenix_kit, "~> 1.7.189")`. The invite-only access
gate does not exist in **any** published core: `deps/phoenix_kit` at 1.7.226 —
the current Hex latest — has an 89-line `PhoenixKit.Users.Referrals` with no
`access_required?/0`, no `grandfather_existing` read, and no
`referral_required_enabled_at`. The gate only exists in the unpublished local
checkout.

Meanwhile the settings page rendered the toggle whenever invite-only was on,
labelled:

> Accounts created before referrals became required keep their access. Turn
> this off and they must enter a code too.

On a published core, turning it off does nothing whatsoever. An operator who
believes they have just closed access to existing users has not. It fails open,
and silently — the worst combination for a control an admin reasons about
security with.

**Fix:** added `PhoenixKitReferrals.access_gate_available?/0`, which probes the
gate's entry point the same way core probes back into this module:

```elixir
def access_gate_available? do
  Code.ensure_loaded?(PhoenixKit.Users.Referrals) and
    function_exported?(PhoenixKit.Users.Referrals, :access_required?, 0)
end
```

The template now renders the toggle only when
`@referral_codes_required and @access_gate_available`. Verified: `false`
against Hex core 1.7.226 (toggle hidden), `true` against the local checkout
(toggle shown). A regression test pins the probe to a function core really
exports, so a rename on core's side fails the suite here rather than hiding the
toggle forever.

The setting itself (`referral_grandfather_existing`) is still written and read
unconditionally — storing the operator's answer on a core that cannot yet act
on it is harmless, and means the toggle lights up correctly the moment core
ships the gate. `grandfather_existing?/0`'s doc now says which half is which,
and records core's full-permissions exemption (an operator cannot lock
themselves out) since that materially changes what "turn it off" means.

**Follow-up (not actionable yet):** once core publishes the gate, raise the pin
to that version. The probe can stay regardless — `~> 1.7` spans cores on both
sides of the change.

### IMPROVEMENT - MEDIUM — DB reads in `mount/3` *(not fixed — pre-existing)*

`web/settings.ex` `mount/3` already performed three settings reads
(`get_project_title/0`, `get_config/0`, and now `grandfather_existing?/0` and
`access_gate_available?/0`). `mount/3` runs twice per page load — once for the
dead HTTP render, once for the socket — so each is queried twice. The
LiveView-correct home for these is `handle_params/3`, which already exists here
and does nothing but assign `:url_path`.

Not fixed: this is the LiveView's pre-existing shape, not something the PR
introduced, and moving the loads means moving all four plus their update paths.
Worth doing as its own change, not smuggled into a review of an unrelated PR.
(`access_gate_available?/0` at least costs no query — it is a code check.)

### NITPICK — Boundary stamp re-implemented `UtilsDate.utc_now/0` *(moot after the HIGH fix)*

`DateTime.utc_now() |> DateTime.truncate(:second)` is exactly
`PhoenixKit.Utils.Date.utc_now/0`, which the module already aliases as
`UtilsDate` and uses elsewhere. Removed along with the stamp; noting it so the
next person reaching for a timestamp here uses the alias.

### NITPICK — Distribution test hardcodes a second copy of the alphabet *(not fixed)*

`test/phoenix_kit_referrals_test.exs` repeats the literal
`~c"ABCDEFGHJKLMNPQRSTUVWXYZ23456789"` rather than reading `@code_alphabet`
(which is private). If the alphabet is ever swapped for a *different* 32-glyph
set, the compile-time guard passes and this test fails with an opaque MapSet
diff. Left as-is: exposing the alphabet purely for a test is a worse trade than
one confusing failure in an unlikely edit, and the failure is at least loud.

## Verified, no change needed

- **`generate_random_code/0` is now unbiased.** `:crypto.strong_rand_bytes(5)`
  → `rem(byte, 32)`; `256 = 8 × 32` divides evenly, so every glyph gets exactly
  8 of the 256 byte values. The compile-time `raise` guarding that invariant is
  correctly placed in the module body (evaluated at compile time) and the
  runtime distribution test is calibrated sanely — 20 000 draws, expected 625
  per glyph, ±40 % band ≈ ±10σ, so it cannot flake but would catch the roughly
  2× skew a bad alphabet size produces.
- **Existing codes keep working.** Alphabet and length are unchanged; the
  change is generator-side only, and `generate_unique_code/1` is untouched.
- **`Settings.update_setting/2` accepts `nil`** (guard is
  `is_binary(value) or is_nil(value)`, stored as `""`), so the removed clear
  path would not have crashed — it was redundant, not broken.
- **Keyspace is unchanged at 32⁵ ≈ 33.5M.** Small for a credential, but the PR
  explicitly scoped itself to the generator and core rate-limits code
  redemption (`RateLimiter`, 10 per 10 minutes per account) — out of scope here,
  noted for the record.

## Gate

`mix precommit` (compile `--warnings-as-errors` + `deps.unlock --check-unused` +
`hex.audit` + `format --check-formatted` + `credo --strict` + `dialyzer`) —
clean. 27 tests, 0 failures.
