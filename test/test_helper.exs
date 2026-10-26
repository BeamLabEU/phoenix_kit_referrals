# Two levels:
#
#   * unit — behaviour, schemas, conformance and the migration SQL as data.
#     Always run, no database needed.
#   * integration — tagged `:integration`; need PostgreSQL and are excluded
#     automatically when it is unavailable.
#
# First-time setup:
#
#   createdb phoenix_kit_referrals_test
#
# Core's versioned chain still creates this module's tables, so the schema is
# built by `PhoenixKit.Migration.ensure_current/2`, the same call a host app
# makes; then this module's own chain (`PhoenixKitReferrals.Migrations`,
# V1 adopts those tables) runs on top, as `mix phoenix_kit.update` runs it.

Code.require_file(Path.expand("support/test_repo.ex", __DIR__))

alias PhoenixKitReferrals.Migrations
alias PhoenixKitReferrals.Test.Repo, as: TestRepo

db_name = Application.get_env(:phoenix_kit_referrals, TestRepo)[:database]

repo_available =
  try do
    {:ok, _} = TestRepo.start_link()

    # `start_link/0` connects lazily; ask a question first.
    TestRepo.query!("SELECT 1")
    PhoenixKit.Migration.ensure_current(TestRepo, log: false)

    # `up/1` needs an `Ecto.Migration` run; the SQL is data, so replay it.
    if Migrations.migrated_version_runtime() < Migrations.current_version() do
      Enum.each(Migrations.up_statements("public"), &TestRepo.query!/1)
    end

    Ecto.Adapters.SQL.Sandbox.mode(TestRepo, :manual)
    true
  rescue
    e ->
      IO.puts("""

        Integration tests excluded — could not reach "#{db_name}".
        Run: createdb #{db_name}

        (#{Exception.message(e)})
      """)

      false
  end

# `migrations_build_alone_test.exs` uses core's
# `PhoenixKit.TestSupport.ModuleChainCheck`, which the first core release after
# 2.64.1 ships; against an older core in `deps/` it is excluded.
chain_check =
  if Code.ensure_loaded?(PhoenixKit.TestSupport.ModuleChainCheck),
    do: [],
    else: [:requires_module_chain_check]

exclude = if repo_available, do: chain_check, else: [:integration | chain_check]
ExUnit.start(exclude: exclude)

# The manifest test builds the module's tables with `ModuleChainCheck.build_alone/4`
# and hands the manifest to repair (`PhoenixKit.Module.expected_schema/0`); both
# arrive in the first core release after 2.64.1.
unless Code.ensure_loaded?(PhoenixKit.TestSupport.ModuleChainCheck) and
         function_exported?(PhoenixKit.TestSupport.ModuleChainCheck, :build_alone, 4) do
  ExUnit.configure(exclude: [:requires_core_expected_schema | ExUnit.configuration()[:exclude]])
end
