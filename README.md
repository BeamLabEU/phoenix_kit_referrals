# PhoenixKitReferrals

[![Hex.pm](https://img.shields.io/hexpm/v/phoenix_kit_referrals.svg)](https://hex.pm/packages/phoenix_kit_referrals)
[![Elixir](https://img.shields.io/badge/Elixir-~%3E_1.18-4B275F)](https://elixir-lang.org)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

Referral codes module for [PhoenixKit](https://github.com/BeamLabEU/phoenix_kit).

Issue and manage referral codes, enforce per-code and per-user limits, track usage, and
(optionally) require or apply a code at user registration.

This module was extracted from PhoenixKit core. The referral tables
(`phoenix_kit_referral_codes`, `phoenix_kit_referral_code_usage`) are still created by
PhoenixKit's own migrations — this package ships the schemas, the business logic, and the
admin UI that read and write them. Installing the package is enough; no extra migration
step is required.

## Features

- **Referral code CRUD** — create, edit, enable/disable, and delete codes from the admin
  panel, with random-code generation and an optional beneficiary user.
- **Validation & limits** — uniqueness, expiration dates, per-code usage caps, and a
  system-wide cap on how many codes a single user can create.
- **Usage tracking** — every redemption is recorded with usage stats (totals, unique
  users, recent activity) for admin dashboards.
- **Signup integration** — when enabled, the registration / OAuth / magic-link flows
  offer (or require) a code and record its usage on success.
- **Referral link capture** — share a link like `https://yourapp.com/?ref=CODE`;
  a visitor's code is remembered (localStorage, 30-day TTL, first-touch) and
  auto-filled at signup later, including through OAuth (Google/Apple/GitHub/Facebook).
- **Auto-discovery** — implements the `PhoenixKit.Module` behaviour; PhoenixKit finds it
  at startup with zero config and exposes an enable/disable toggle and a permission key.

## Installation

Add it to your PhoenixKit host app's deps:

```elixir
def deps do
  [
    {:phoenix_kit, "~> 1.7"},
    {:phoenix_kit_referrals, "~> 0.6"}
  ]
end
```

Then fetch dependencies:

```bash
mix deps.get
```

It is auto-discovered at compile time (via `extra_applications: [:phoenix_kit]` and the
`PhoenixKit.Module` behaviour) — the admin tabs, settings page, and routes appear
automatically. Enable it from **Admin → Modules**.

## What you get

- **Admin → Users → Referrals** — list, create, edit, and enable/disable codes, with
  per-code usage stats.
- **Admin → Settings → Referrals** — turn the system on, make a code required at signup,
  and cap uses-per-code / codes-per-user.
- **Signup integration** — PhoenixKit core dispatches to this module at runtime by module
  key, so core has no compile-time dependency on it: with the module absent the field
  simply doesn't appear.

## Referral link capture

Entering a referral code by hand is friction most users skip, so this module also
accepts codes via URL:

1. Share `https://yourapp.com/?ref=CODE` (any page — it doesn't have to be the signup
   page). `?referral=CODE` is also accepted as an alias.
2. A small script shipped by this module (see [JS integration](#js-integration) below)
   stores the code in the visitor's `localStorage` for 30 days and strips the param
   from the address bar. If the visitor already has a stored code, a later link won't
   overwrite it (first-touch attribution).
3. Whenever the visitor reaches registration, magic-link registration, or clicks an
   OAuth provider button, the stored code is applied automatically — the existing
   `referral_code` form field is filled in, or `?referral_code=` is appended to the
   OAuth link. From there it flows through PhoenixKit core's existing
   registration/OAuth handling exactly as if the visitor had typed it in.

No database schema changes or core `phoenix_kit` changes are required — capture and
autofill are pure client-side script working with fields/links core already renders
and already reads server-side.

### JS integration

Ships a prebuilt script via `PhoenixKit.Module.js_sources/0`, the same mechanism
`phoenix_kit_crm` uses. Any host that has already installed `phoenix_kit`'s JS
integration (done once by `mix phoenix_kit.install` / `mix phoenix_kit.update`) picks
this up automatically on the next compile — no manual `app.js` or layout edits needed.

To change the capture window, set before the bundle loads:

```html
<script>window.PhoenixKitReferralsConfig = {ttlDays: 14};</script>
```

## Settings

Configured from **Admin → Settings → Referrals** and persisted via `PhoenixKit.Settings`:

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `referral_codes_enabled` | boolean | `false` | Module on/off |
| `referral_codes_required` | boolean | `false` | Require a valid code at registration |
| `max_number_of_uses_per_code` | integer | `100` | System-wide cap on uses per code |
| `max_number_of_codes_per_user` | integer | `10` | System-wide cap on codes a user can create |

## Public API

`PhoenixKitReferrals` is the context (and the `ReferralCode` schema). Highlights:

- **Codes** — `list_codes/0`, `list_valid_codes/0`, `get_code/1`, `get_code!/1`,
  `get_code_by_string/1`, `create_code/1`, `update_code/2`, `delete_code/1`,
  `change_code/2`, `generate_random_code/0`
- **Validation** — `valid_for_use?/1`, `expired?/1`, `usage_limit_reached?/1`
- **Usage** — `use_code/2`, `get_usage_stats/1`, `list_usage_for_code/1`,
  `user_used_code?/2`
- **Limits** — `validate_user_code_limit/1`, `count_user_codes/1`
- **System** — `enabled?/0`, `required?/0`, `enable_system/0`, `disable_system/0`,
  `set_required/1`, `get_config/0`, `get_system_stats/0`,
  `get_max_uses_per_code/0` / `set_max_uses_per_code/1`,
  `get_max_codes_per_user/0` / `set_max_codes_per_user/1`

```elixir
# Create a code
{:ok, code} =
  PhoenixKitReferrals.create_code(%{
    code: "WELCOME",
    description: "Welcome promotion",
    max_uses: 100
  })

# Redeem it for a user (by UUID)
case PhoenixKitReferrals.use_code("WELCOME", user_uuid) do
  {:ok, _usage} -> :ok
  {:error, :code_expired} -> :handle
  {:error, :usage_limit_reached} -> :handle
  {:error, reason} -> {:error, reason}
end
```

## Local development

`phoenix_kit` resolves from Hex by default. To run against a local PhoenixKit checkout
(e.g. an unpublished core change), export `PHOENIX_KIT_PATH` and Mix swaps the Hex pin
for a local `path:` dep at resolve time:

```bash
PHOENIX_KIT_PATH=../phoenix_kit mix test
```

Unset, the published pin is used — so `mix hex.publish` and CI are unaffected.

```bash
mix deps.get       # Install dependencies
mix test           # Run tests
mix format         # Format code
mix credo --strict # Static analysis
mix dialyzer       # Type checking
mix docs           # Generate documentation
```

## License

MIT — see [LICENSE](LICENSE) for details.
