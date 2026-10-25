# AGENTS.md

This file provides guidance to AI agents when working with code in this repository.

## Project Overview

PhoenixKit Referrals module — issue and manage referral codes, enforce per-code and
per-user limits, track usage, and (optionally) require or apply a code at user
registration. Implements the `PhoenixKit.Module` behaviour for auto-discovery by a
parent Phoenix application.

This module was **extracted from PhoenixKit core**. Core's versioned migrations still
create the two referral tables (`phoenix_kit_referral_codes`,
`phoenix_kit_referral_code_usage`), but their shape is this module's:
`PhoenixKitReferrals.Migrations` (its V1 adopts them) is where every change goes.
`mix phoenix_kit.update` runs it after core's chain; nothing to do by hand.

## Common Commands

```bash
mix deps.get                # Install dependencies
mix test                    # Run all tests
mix test test/phoenix_kit_referrals_test.exs  # Run a specific test file
createdb phoenix_kit_referrals_test           # once; the migration tests need it (excluded without it)
mix format                  # Format code (imports Phoenix LiveView rules)
mix credo --strict          # Static analysis / linting
mix dialyzer                # Type checking
mix docs                    # Generate documentation
mix quality                 # format + credo --strict + dialyzer
mix quality.ci              # format --check-formatted + credo --strict + dialyzer
mix precommit               # compile (warnings-as-errors) + deps.unlock --check-unused + hex.audit + quality.ci
```

Always run `mix precommit` before committing.

## Architecture

This is a **library** (not a standalone Phoenix app) that provides referral codes as a
PhoenixKit plugin module. It has no endpoint, router, or repo of its own — it uses the
host app's repo via `PhoenixKit.RepoHelper.repo/0`.

### File Layout

```
lib/
  phoenix_kit_referrals.ex                     # Main module — ReferralCode schema + context + PhoenixKit.Module behaviour
  phoenix_kit_referrals/
    migrations.ex                              # Own migration chain (V1 adopts the two core-created tables)
    referral_code_usage.ex                     # ReferralCodeUsage schema + usage queries/stats
    paths.ex                                   # Centralized URL path helpers
    routes.ex                                  # Admin route macros (admin_routes/0, admin_locale_routes/0)
    web/
      list.ex / list.html.heex                 # Admin list/management LiveView (under Users)
      form.ex / form.html.heex                 # New/edit referral form LiveView
      settings.ex / settings.html.heex         # Admin settings LiveView (under Settings)
```

### Key Modules

- **`PhoenixKitReferrals`** (`lib/phoenix_kit_referrals.ex`) — Does double duty: the
  Ecto schema for `phoenix_kit_referral_codes` **and** the context module (code CRUD,
  validation, usage recording, system settings) **and** the `PhoenixKit.Module`
  behaviour implementation.
- **`PhoenixKitReferrals.ReferralCodeUsage`** (`referral_code_usage.ex`) — Schema for
  `phoenix_kit_referral_code_usage`; provides per-code / per-user usage queries and
  `get_usage_stats/1`.
- **`PhoenixKitReferrals.Paths`** (`paths.ex`) — Centralized path helpers
  (`index/0`, `new/0`, `edit/1`, `settings/0`). All navigation goes through
  `PhoenixKit.Utils.Routes.path/1` for prefix/locale handling. **Never hardcode URLs**
  in LiveViews or templates — add a helper here instead.
- **`PhoenixKitReferrals.Routes`** (`routes.ex`) — Quoted `live` route declarations
  spliced into core's `live_session :phoenix_kit_admin` (both localized and
  non-localized variants). Referenced via `route_module/0`.
- **`PhoenixKitReferrals.Web.{List, Form, Settings}`** — Admin LiveViews. They use
  `use PhoenixKitWeb, :live_view`, so PhoenixKit's core components, Gettext, and the
  admin layout are wired automatically.

### How It Works

1. Parent app adds this as a dependency in `mix.exs`.
2. PhoenixKit scans `.beam` files at startup and auto-discovers the module (zero config)
   — enabled by `:phoenix_kit` in `extra_applications` + `use PhoenixKit.Module`.
3. `admin_tabs/0` registers the management page under **Users**; `settings_tabs/0`
   registers the settings page under **Settings**; `route_module/0` contributes the
   `live` routes. PhoenixKit compiles them into its own admin `live_session`.
4. Settings are persisted via the `PhoenixKit.Settings` API (DB-backed in parent app).
5. Permissions are declared via `permission_metadata/0` (key `"referrals"`) and checked
   via `Scope.has_module_access?/2`.

### Signup integration (runtime dispatch)

When enabled, the registration / OAuth / magic-link flows offer (or require) a referral
code and record its usage on success. **PhoenixKit core dispatches to this module at
runtime by module key**, so core carries no compile-time dependency on it: with the
module absent the registration field simply doesn't appear.

### Settings Keys

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `referral_codes_enabled` | boolean | `false` | Module on/off |
| `referral_codes_required` | boolean | `false` | Require a valid code at registration |
| `max_number_of_uses_per_code` | integer | `100` | System-wide cap on uses per code |
| `max_number_of_codes_per_user` | integer | `10` | System-wide cap on codes a user can create |

Booleans/integers are written through `Settings.update_boolean_setting_with_module/3`
and `Settings.update_setting_with_module/3` with the module tag `"referral_codes"`.

### Database tables and migrations

- `phoenix_kit_referral_codes` — referral codes (UUIDv7 PK); `created_by_uuid` /
  `beneficiary_uuid` hold user uuids (Ecto associations to `phoenix_kit_users`, with no
  database foreign key), and a `has_many` to usage records.
- `phoenix_kit_referral_code_usage` — one row per (code, user) usage event; its
  `code_uuid` is the one database foreign key (`fk_referral_code_usage_code_uuid`,
  `ON DELETE CASCADE`).

**`PhoenixKitReferrals.Migrations`** is the module's versioned chain (`migration_module/0`),
marker `pkref_schema:<N>` as a `COMMENT ON TABLE` on `phoenix_kit_referral_codes` (none
reads as 0), currently **V1**. The SQL is data (`up_statements/2`, `down_statements/2`);
`up/1` / `down/1` `execute/1` it, so they only work inside an `Ecto.Migration` run.

- **V1 adopts the two tables core's chain creates**, exactly as a fresh core install builds
  them (core's V135 baseline; no later core version reshapes them), with core's names. On
  existing installs only the marker is new; where core no longer creates the tables, the
  same statements create them.
- **A change to these tables is a new version here, never a core migration** — core refuses
  one since V223 (its `PhoenixKit.Migrations.ModuleOwnedTables`; plan: core's
  `dev_docs/plans/2026-10-25-module-table-ownership.md`). Until core's `ExpectedSchema` hands
  the tables over, a version that reshapes an object the manifest declares must take it out
  of the manifest first, or `mix phoenix_kit.repair` restores the old shape; one that only
  adds objects the manifest never names needs no core step.
- **Never edit a shipped version's statements**: append behind `target >= N` in
  `up_statements/2` and bump `@current_version`. **`down/1` never drops a table**
  (`migrations_test.exs` asserts no emitted statement matches `DROP|TRUNCATE|DELETE`).
- **Tests:** `test/phoenix_kit_referrals/migrations_test.exs` pins every table, index and
  constraint name, the FK's delete action and prefix threading, and checks the statements
  against core's manifest; `test/integration/migrations_build_alone_test.exs` runs core's
  `PhoenixKit.TestSupport.ModuleChainCheck` (core after 2.64.1) to prove the chain builds the
  tables without core. They use `PhoenixKitReferrals.Test.Repo` (`test/support/test_repo.ex`)
  against `phoenix_kit_referrals_test`; `test_helper.exs` builds core's chain with
  `ensure_current/2`, replays `up_statements/1`, and excludes `:integration` without a
  database.

## Critical Conventions

- **Module key** is `"referrals"` and must be consistent across `module_key/0`,
  `permission_metadata/0` (`:key`), and tab `:permission` fields.
- **Tab IDs**: `:admin_referrals` is its own top-level section (NOT nested under
  `:admin_users` — this module is meant to eventually be reachable by non-Owner/Admin
  roles holding only the `"referrals"` permission, which a section gated on full
  user-management access can't allow), with subtabs `:admin_referrals_overview` and
  `:admin_referrals_codes`. `:admin_settings_referrals` is the separate Settings tab.
- **URL paths**: `/admin/referral-codes/overview` and `/admin/referral-codes/codes`
  (+ `/new`, `/edit/:code_uuid`) are siblings under `/admin/referral-codes` — deliberately
  neither nested inside the other, since prefix-based active-tab matching would otherwise
  highlight both tabs at once for one of the two pages. `/admin/settings/referral-codes`
  is separate, under Settings.
- **Navigation paths**: always go through `PhoenixKitReferrals.Paths` (which wraps
  `PhoenixKit.Utils.Routes.path/1`) — never hardcode or use relative paths. Core
  destinations outside this module (e.g. `/admin/modules`) may call `Routes.path/1`
  directly.
- **`enabled?/0`** rescues errors and returns `false` (the DB may be unavailable at
  boot).
- **UUIDv7 primary keys** — both schemas use `@primary_key {:uuid, UUIDv7, autogenerate: true}`.
- **No own repo** — always reach the repo via `PhoenixKit.RepoHelper.repo/0` (the private
  `repo/0` helper in the main module).
- **Admin routing** — plugin routes are auto-discovered and compiled into
  `live_session :phoenix_kit_admin`. Never hand-register them in a parent app's
  `router.ex`.

## Tailwind CSS Scanning

The module renders daisyUI/Tailwind templates, so it implements
`css_sources/0` returning `[:phoenix_kit_referrals]`. PhoenixKit's compile-time CSS
source discovery scans the listed apps' templates; without this, Tailwind would purge
classes unique to this module.

## JS Hook Bundle — Referral Link Capture

This package has no router/signup UI/OAuth code of its own (those live in core
`phoenix_kit`), so URL-based referral capture (`?ref=CODE`, `?referral=CODE` alias -> localStorage ->
auto-filled at signup, including OAuth) is implemented entirely as a client-side
script rather than a server-side change:

- `js_sources/0` (`lib/phoenix_kit_referrals.ex`, **no `@impl`** — older core releases
  don't declare this callback; annotating it would warn under
  `--warnings-as-errors`) ships `priv/static/assets/phoenix_kit_referrals.js` under the
  global `PhoenixKitReferralsHooks`. Core's `:phoenix_kit_js_sources` compiler folds it
  into the host's `phoenix_kit_modules.js`, already spread into `window.PhoenixKitHooks`
  / LiveSocket by the host's `app.js` (wired once by `mix phoenix_kit.install` /
  `mix phoenix_kit.update` — no manual host action needed). Mirrors `phoenix_kit_crm`.
- The script is plain script, not a `phx-hook` — a referral link can land on any page
  of the host site, so there's no single DOM element to attach a hook to. It runs on
  script load, `DOMContentLoaded`, and `phx:page-loading-stop` (LiveView navigation).
- It relies only on markup core already renders and already reads server-side —
  `document.getElementById("referral_code")` (the plain `<input>` in
  `registration.html.heex` / `magic_link_registration.html.heex`, read via
  `params["referral_code"]`) and `a[href*="/users/auth/"]` (OAuth provider links in
  `oauth_buttons.ex`; the OAuth controller already reads `params["referral_code"]` into
  the session — see `PhoenixKitWeb.Users.OAuth.handle_oauth_request/4`). **If core ever
  renames/removes the `referral_code` field id or the OAuth path prefix, this script
  silently stops autofilling — it fails open, not loudly.**
- First-touch attribution: an existing, still-valid stored code is never overwritten by
  a later `?ref=`/`?referral=` link. TTL defaults to 30 days; a host can override via
  `window.PhoenixKitReferralsConfig = {ttlDays: N}` before the bundle loads.

## Local cross-repo development

`phoenix_kit` resolves from Hex by default. To build or test against a **local checkout**
of core — e.g. an unpublished core change — export `PHOENIX_KIT_PATH` and Mix swaps the
Hex pin for a `path:` + `override: true` dep at resolve time (via `pk_dep/3` in `mix.exs`):

```bash
PHOENIX_KIT_PATH=../phoenix_kit mix test
```

The variable name is the dep's app name upper-cased with `_PATH` appended. **Unset = the
published pin**, so `mix hex.publish` and CI resolve exactly as before. Never hand-edit a
`phoenix_kit*` dep into a `path:` tuple — a committed path dep ships a broken package; set
the env var instead.

## Versioning & Releases

This project follows [Semantic Versioning](https://semver.org/). Tags use **bare version
numbers** (no `v` prefix).

### Version locations

The version must be updated in **three places** when bumping:

1. `mix.exs` — `@version` module attribute
2. `lib/phoenix_kit_referrals.ex` — `version/0` callback
3. `test/phoenix_kit_referrals_test.exs` — version compliance test

The compliance test also asserts `version/0` equals the app's loaded `:vsn`, so a
mismatch between `mix.exs` and `version/0` fails the suite.

### Full release checklist

1. Update the version in all three places above.
2. Add a changelog entry in `CHANGELOG.md`.
3. Run `mix precommit` — ensure zero warnings/errors before proceeding.
4. Commit all changes: `"Bump version to x.y.z"`.
5. Push to main and **verify the push succeeded** before tagging.
6. Create and push the git tag: `git tag x.y.z && git push origin x.y.z`.
7. Create the GitHub release: `gh release create x.y.z --title "x.y.z - YYYY-MM-DD" --notes "..."`.
8. Publish to Hex: `mix hex.publish`.

**IMPORTANT:** Never tag or create a release before all changes are committed and pushed.
Tags are immutable pointers — tagging before pushing means the release points at the
wrong commit.

## Pull Requests

### Commit Message Rules

Start with action verbs: `Add`, `Update`, `Fix`, `Remove`, `Merge`.

### PR Reviews

PR review files go in `dev_docs/pull_requests/{year}/{pr_number}-{slug}/`. Use
`{AGENT}_REVIEW.md` naming (e.g., `CLAUDE_REVIEW.md`, `GEMINI_REVIEW.md`). Severity
levels: `BUG - CRITICAL`, `BUG - HIGH`, `BUG - MEDIUM`, `IMPROVEMENT - HIGH`,
`IMPROVEMENT - MEDIUM`, `NITPICK`.

## External Dependencies

- **PhoenixKit** (`~> 1.7`, via `pk_dep/3`) — Module behaviour, Settings API, shared
  components, RepoHelper, Utils (Date, UUID, Routes), `Users.Auth`, Dashboard tabs.
- **Phoenix LiveView** (`~> 1.1`) — admin LiveViews.
- **ex_doc** (`~> 0.34`, dev only) — documentation generation.
- **credo** (`~> 1.7`, dev/test) — static analysis.
- **dialyxir** (`~> 1.4`, dev/test) — type checking.
- **lazy_html** (test only) — HTML parser for `Phoenix.LiveViewTest` smoke tests.
