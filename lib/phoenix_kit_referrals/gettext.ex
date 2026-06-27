defmodule PhoenixKitReferrals.Gettext do
  @moduledoc """
  Gettext backend for the referrals module's own translations.

  The module's admin LiveViews `use PhoenixKitWeb` (which binds the gettext
  macros to core's `PhoenixKitWeb.Gettext`) and then `use Gettext, backend:
  PhoenixKitReferrals.Gettext` to rebind them to this backend, so the referrals
  strings resolve against **this** package's catalogs (`priv/gettext`). Tab
  labels pass this module as their `gettext_backend`. Keeps the referrals
  translations self-contained — extract + translate with the module's own
  `mix gettext.extract` / `mix gettext.merge`.
  """
  use Gettext.Backend, otp_app: :phoenix_kit_referrals
end
