defmodule PhoenixKitReferrals.Test.Repo do
  @moduledoc """
  Test-only Ecto repo for the migration tests.

  Configured in `config/test.exs`, started by `test_helper.exs`. Uses
  `Ecto.Adapters.SQL.Sandbox`.
  """
  use Ecto.Repo,
    otp_app: :phoenix_kit_referrals,
    adapter: Ecto.Adapters.Postgres
end
