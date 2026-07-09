# Changelog

All notable changes to **PhoenixKitReferrals** are documented here. The format
follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and this
project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Fixed

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
