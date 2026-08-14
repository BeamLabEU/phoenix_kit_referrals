# Changelog

All notable changes to **PhoenixKitReferrals** are documented here. The format
follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and this
project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- `signup_use_exists?/1` / `ReferralCodeUsage.exists_for_user?/1` — whether a
  user has ever redeemed any referral code. Core's invite-only access gate
  uses this to lazily stamp accounts that redeemed under referrals 0.4,
  which have a usage row but no `referral_satisfied_at`.

## 0.6.1 - 2026-08-11

### Changed

- Dependency updates: `phoenix_kit` 2.2.0 and the transitive set it pulls
  (`phoenix` 1.8.10, `hackney` 4.7.3). No source changes in this package.

## [0.6.0] - 2026-08-10

### Changed

- **⚠️ Requires `phoenix_kit ~> 2.0`.** The core pin moved to `~> 2.0`, so this
  release no longer resolves against core 1.7.

  Core 2.0.0 squashes the migration chain into a single `V135` baseline and makes
  V135 the chain's floor: `mix ecto.migrate` now *refuses* on a database below it
  rather than migrating. Check `mix phoenix_kit.status` **before** upgrading. A
  host below V135 must install `phoenix_kit 1.7.236` — the migration bridge, the
  last release carrying the full pre-squash chain — migrate until the reported
  version is at least V135, and only then move to 2.0.

  This package does not call migration internals, so the change is the pin
  itself.

## [0.5.0] - 2026-08-03

### Security

- **Generated referral codes now come from a CSPRNG.** `generate_random_code/0`
  draws from `:crypto.strong_rand_bytes/1` instead of `Enum.random/1`. `:rand`
  is seeded per process and is not built to resist an observer, and codes are
  handed out by design (including in `?ref=CODE` links) — under
  `referral_codes_required` a predictable code is a predictable way into the
  site. The alphabet and length are unchanged, so existing codes keep working.
- A compile-time guard now rejects a `@code_alphabet` whose size does not divide
  256 evenly, since the `rem(byte, size)` mapping would silently bias toward the
  low characters and shrink the keyspace. A distribution test covers the runtime
  half.

### Added

- **Grandfathering toggle for the invite-only access gate.** A new
  `referral_grandfather_existing` setting (default `true`) records whether
  accounts created before referrals became required keep their access, with
  `grandfather_existing?/0` / `set_grandfather_existing/1` and a toggle on the
  referrals settings page. Core's invite-only access gate is what reads and
  enforces it — see the "Invite-only access gate" section of
  `PhoenixKit.Users.Referrals`.
- `access_gate_available?/0` — whether the installed core actually has that
  gate. The `phoenix_kit` requirement spans versions from before it existed, so
  the settings page asks first and hides the grandfathering toggle rather than
  offering a switch wired to nothing.

## [0.4.0] - 2026-07-11

### Added

- **Referral program overview page** (`/admin/referral-codes/overview`,
  `PhoenixKitReferrals.Web.Overview`) — a read-only admin dashboard with
  system-wide stats, a top-codes-by-usage leaderboard, and a recent-activity
  feed across every code. Adds `PhoenixKitReferrals.top_codes/1`,
  `list_recent_usage/1`, and a `:user` association on
  `ReferralCodeUsage` (via the existing `used_by_uuid` column, no migration).
- **Admin nav: "Referrals" is now its own top-level section** (`:admin_referrals`,
  mirroring `phoenix_kit_ai`'s `:admin_ai`), no longer nested under Users, and its
  URLs no longer live under `/admin/users/*` either — Overview and Codes (formerly
  labeled "Referrals") now live at `/admin/referral-codes/overview` and
  `/admin/referral-codes/codes` (+ `/new`, `/edit/:code_uuid`), true siblings so
  neither prefix-matches the other's nav tab. Deliberate: unlike user management,
  this module is meant to eventually be reachable by non-Owner/Admin roles holding
  only the `"referrals"` permission, so it can't live inside a section (or URL
  namespace) gated on full user-management access.
- **New-code form pre-fills "Maximum Uses"** with the system default
  (`get_max_uses_per_code/0`, 100 unless configured otherwise) instead of leaving
  a required field blank — still freely editable.

### Fixed

- **The new/edit form silently dropped every typed field.** `validate_code` and
  `save_code` read submitted params under the key `"referrals"`, but the form's
  actual param key — derived from the `%PhoenixKitReferrals{}` changeset's struct
  module — is `"phoenix_kit_referrals"`. Every `phx-change`/`phx-submit` therefore
  rebuilt the changeset from an empty map, silently discarding the generated code
  and anything typed, and (once `:action` was set) surfacing "can't be blank" on
  every required field.

- **`use_code/2` could crash user registration.** Recording a use ran the code
  through the full `changeset/2`, which re-validates `max_uses` against the
  current system limit. Lowering `max_number_of_uses_per_code` therefore made
  every pre-existing code with a larger `max_uses` fail its usage update, and the
  `{:ok, _} = update_code(...)` match raised. The counter is now incremented with
  a conditional `UPDATE` that touches no changeset.
- **The usage counter raced.** `valid_for_use?/1` read `number_of_uses` and a
  later `update_code/2` wrote `read + 1`, so two concurrent sign-ups on a code
  with one slot left both succeeded. The increment is now atomic and re-checks
  status, expiration, and the limit in the database.
- **Expired codes could not be edited or deactivated.** `changeset/2` validated
  `expiration_date` and `max_uses` via `get_field/2`, so a persisted past
  expiration — or a `max_uses` predating a lowered system limit — failed
  validation on *every* update, including one that only flipped `status`. Both
  now validate via `get_change/2` and fire only when the field is actually being
  set.
- **A user could use the same code repeatedly.** `use_code/2` now rejects a
  repeat with `{:error, :already_used}`, serialized by the row lock the counter
  increment takes.
- **`unique_constraint(:code)` and `foreign_key_constraint(:code_uuid)` never
  matched.** Core names these `phoenix_kit_referral_codes_code_uidx` and
  `fk_referral_code_usage_code_uuid`, not Ecto's defaults, so violations escaped
  as `Postgrex.Error` instead of changeset errors. Both now pass `:name`.
- **`list_valid_codes/0` omitted never-expiring codes.** Its `expiration_date >
  now` filter is NULL-false, contradicting `valid_for_use?/1`, which treats a
  `nil` expiration as valid.
- **Code lookup is now case-insensitive.** A user typing `welcome2024` for
  `WELCOME2024` was told the code was invalid. Codes are also trimmed and upcased
  on write, so they are stored in one canonical case.
- **`generate_random_code/0` could not produce a repeated character.** It sampled
  the alphabet with `Enum.take_random/2` (without replacement), cutting the
  keyspace from 32⁵ to 32·31·30·29·28.

### Added

- `generate_unique_code/1`, which retries until it finds a code no existing
  record holds. The admin form's "generate" button now uses it.

### Changed

- `number_of_uses` is no longer castable through `changeset/2`. The counter is
  owned by `use_code/2`.
- `use_code/2` reports an inactive code as `{:error, :code_inactive}` before
  considering expiry or the usage limit, matching the precedence core's
  registration LiveView already used for its own messages.

## [0.3.0] - 2026-07-05

### Added

- Referral link capture via URL query param. Share `https://yourapp.com/?ref=CODE`
  (`?referral=CODE` also accepted) — a client-side script (shipped via `js_sources/0`,
  the same mechanism `phoenix_kit_crm` uses) stores the code in the visitor's
  `localStorage` for 30 days (first-touch attribution, configurable via
  `window.PhoenixKitReferralsConfig = {ttlDays: N}`) and strips the param from the
  address bar. At registration, magic-link registration, or OAuth sign-in
  (Google/Apple/GitHub/Facebook), the stored code auto-fills the existing
  `referral_code` field or is appended to the OAuth link — using fields/links
  PhoenixKit core already renders and reads server-side, so no core changes are
  required.

## [0.2.0] - 2026-06-27

### Added

- Internationalization for the admin UI. A module-owned Gettext backend
  (`PhoenixKitReferrals.Gettext`) with its own `priv/gettext` catalogs; every
  admin-facing string in the list, form, and settings LiveViews — plus the
  `permission_metadata/0` label and description — now resolves through
  `gettext/1`. Ships full **Russian** and **Estonian** translations alongside
  the English source. The `priv` directory is now included in the Hex package so
  the catalogs travel with the build.

### Fixed

- Delete-confirmation on the referrals list now uses LiveView's native
  `data-confirm` instead of an inline `onclick="return confirm(...)"`. The
  previous handler did not reliably stop the `phx-click` delete when the user
  cancelled, and interpolating a translated string into a JS literal would break
  on any translation containing an apostrophe.

## [0.1.0]

### Added

- Initial release. Extracted the referral-codes feature out of PhoenixKit core
  into a standalone, auto-discovered module:
  - `PhoenixKitReferrals` context — code CRUD, validation, usage tracking, and
    system settings (enabled / required / per-code + per-user limits).
  - Admin UI — referral-code list/form and a settings page, contributed via the
    `PhoenixKit.Module` tab callbacks.
  - Signup integration via runtime dispatch from core (registration, OAuth, and
    magic-link), so core carries no compile-time dependency on this module.
  - The referral tables remain owned by PhoenixKit core migrations; this package
    ships only schemas, logic, and UI.
