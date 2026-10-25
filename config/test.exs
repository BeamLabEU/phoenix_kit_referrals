import Config

config :logger, level: :warning

# The migration tests run against a real PostgreSQL database. Create it with:
#   createdb phoenix_kit_referrals_test
# Without it, `test_helper.exs` excludes the `:integration` tests.
config :phoenix_kit_referrals, ecto_repos: [PhoenixKitReferrals.Test.Repo]

# `PGDATABASE` points the suite at a database the role may not CREATE, and
# `PGPOOL` bounds the pool, as in core's config/test.exs.
pg_test_db =
  case System.get_env("PGDATABASE") do
    value when is_binary(value) and value != "" -> String.trim(value)
    _ -> "phoenix_kit_referrals_test#{System.get_env("MIX_TEST_PARTITION")}"
  end

pg_test_pool =
  case System.get_env("PGPOOL") do
    value when is_binary(value) and value != "" ->
      case Integer.parse(String.trim(value)) do
        {size, ""} when size > 0 -> size
        _ -> raise "PGPOOL must be a positive integer, got: #{inspect(value)}"
      end

    _ ->
      System.schedulers_online() * 2
  end

config :phoenix_kit_referrals, PhoenixKitReferrals.Test.Repo,
  username: System.get_env("PGUSER", "postgres"),
  password: System.get_env("PGPASSWORD", "postgres"),
  hostname: System.get_env("PGHOST", "localhost"),
  database: pg_test_db,
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: pg_test_pool

# `PhoenixKit.RepoHelper` resolves this (the chain's version reader uses it).
config :phoenix_kit, repo: PhoenixKitReferrals.Test.Repo
