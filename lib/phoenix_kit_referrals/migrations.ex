defmodule PhoenixKitReferrals.Migrations do
  @moduledoc """
  Module-owned versioned migrations for `phoenix_kit_referrals` — the protocol
  core's `mix phoenix_kit.update` discovers through `migration_module/0`:
  `current_version/0`, `migrated_version_runtime/1`, an idempotent `up/1` and a
  version-aware `down/1`. Same shape as `phoenix_kit_locations`' chain.

  ## What V1 is

  An ADOPTION step for the two tables core's chain creates for this module:
  `phoenix_kit_referral_codes` and `phoenix_kit_referral_code_usage`. Their shape is core's V135 baseline; no later core version reshapes them. The statements below re-state what a fresh core install builds today, with core's exact object names.

    * On every existing install the tables are already there: each `CREATE
      TABLE IF NOT EXISTS`, guarded `DO $$ … pg_constraint … $$` block and
      `CREATE INDEX IF NOT EXISTS` finds its target and does nothing. The only
      new object is the `pkref_schema:1` marker.
    * On an install whose core no longer creates the tables, the same
      statements create them, identical to what core built.
      `test/integration/migrations_build_alone_test.exs` proves that against
      core's chain (core's `PhoenixKit.TestSupport.ModuleChainCheck`).

  From V1 on, this chain owns the tables' shape: a change to them is a new
  version here, never a core migration (core enforces that since V223; see
  core's `dev_docs/plans/2026-10-25-module-table-ownership.md`). Until core's
  `ExpectedSchema` manifest hands these tables over, a version that reshapes an
  object the manifest declares must first take it out of the manifest, or
  `mix phoenix_kit.repair` restores the old shape; a version that only adds
  objects the manifest never names needs no core step.

  ## What `down/1` is NOT

  `down/1` rewrites the version marker; it never drops a table. The rows are
  the site's referral codes and their usage, and on every current install core
  created the tables.
  `test/phoenix_kit_referrals/migrations_test.exs` pins this by asserting that no
  statement this module can emit matches `DROP`, `TRUNCATE` or `DELETE`.

  ## Adding a version

  1. Append the new statements to `up_statements/2` behind `target >= N`
     (never edit V1's statements: hosts past V1 never re-run them).
  2. Bump `@current_version`.

  The migrated version is a `pkref_schema:<N>` `COMMENT ON TABLE` marker on
  `phoenix_kit_referral_codes`; a table without one reads as version 0 — the shape
  core built before this chain existed.
  """

  use Ecto.Migration

  @current_version 1
  @marker_prefix "pkref_schema:"
  @version_table "phoenix_kit_referral_codes"

  @spec current_version() :: pos_integer()
  def current_version, do: @current_version

  @doc "The table carrying the `pkref_schema:<N>` marker (auditor contract)."
  @spec version_table() :: String.t()
  def version_table, do: @version_table

  @doc "The chain version read from INSIDE a migration (migration repo)."
  def migrated_version(opts \\ []) do
    prefix = validated_prefix(opts)
    %{rows: rows} = repo().query!(marker_query(), [prefix])
    rows |> List.first() |> marker_to_version()
  end

  @doc """
  The chain version currently applied in the database, read OUTSIDE a
  migration (the protocol shape core's update task calls — `opts` with
  `:prefix`): the `pkref_schema:<N>` marker when present; a marker-less table
  reads as `0` (core's shape — V1 is purely adoptive, there is no pre-chain
  content to defend).

  `catch :exit` matters as much as `rescue`: a dead or unstarted pool exits
  rather than raising, and `mix phoenix_kit.status` calls this across every
  installed module.
  """
  def migrated_version_runtime(opts \\ []) do
    prefix = validated_prefix(opts)

    case PhoenixKit.RepoHelper.repo().query(marker_query(), [prefix]) do
      {:ok, %{rows: rows}} -> rows |> List.first() |> marker_to_version()
      _ -> 0
    end
  rescue
    # An invalid prefix must surface as the validation error, not be
    # swallowed into 0 ("not installed").
    e in ArgumentError -> reraise e, __STACKTRACE__
    _ -> 0
  catch
    :exit, _ -> 0
  end

  @doc "Applies every chain version up to `target` (`:version` in `opts`, default `current_version/0`); idempotent."
  def up(opts \\ []) do
    prefix = validated_prefix(opts)

    target =
      if is_list(opts), do: Keyword.get(opts, :version, @current_version), else: @current_version

    prefix
    |> up_statements(target)
    |> Enum.each(&execute/1)
  end

  @doc "Rolls back to `target` (`:version` in `opts`). Never drops a table — see the moduledoc."
  def down(opts \\ []) do
    prefix = validated_prefix(opts)
    target = if is_list(opts), do: Keyword.get(opts, :version, 0), else: 0

    prefix
    |> down_statements(target)
    |> Enum.each(&execute/1)
  end

  @doc """
  The SQL `up/1` executes, as data — the testable single source. Every
  statement is idempotent (`IF NOT EXISTS` / guarded `DO $$` block /
  `COMMENT`), so it is safe to replay on an install where core already created
  the tables and on one with none of them.

  V1 order: every `CREATE TABLE`, then every constraint guard (primary keys,
  then the foreign key), then every index, then the version marker last.

  `target` selects how much of the chain to emit (default `current_version/0`);
  the wrapper migration core's update task generates passes an explicit
  `:version`, and a stale wrapper asking for an older version must not receive
  a newer version's objects.
  """
  @spec up_statements(String.t(), pos_integer()) :: [String.t()]
  def up_statements(prefix \\ "public", target \\ @current_version)

  def up_statements(prefix, target) when is_integer(target) and target >= 1 do
    prefix = validated_prefix(prefix: prefix)
    p = "#{prefix}."
    target = min(target, @current_version)

    List.flatten([
      v1_statements(prefix, p),
      "COMMENT ON TABLE #{p}#{@version_table} IS '#{@marker_prefix}#{target}'"
    ])
  end

  @doc "The SQL `down/1` executes, as data (marker bookkeeping only)."
  @spec down_statements(String.t(), non_neg_integer()) :: [String.t()]
  def down_statements(prefix \\ "public", target \\ 0)
      when is_integer(target) and target >= 0 do
    prefix = validated_prefix(prefix: prefix)
    p = "#{prefix}."

    if target > 0 do
      ["COMMENT ON TABLE #{p}#{@version_table} IS '#{@marker_prefix}#{target}'"]
    else
      ["COMMENT ON TABLE #{p}#{@version_table} IS NULL"]
    end
  end

  # ── V1: adoption of the tables core's chain creates ─────────────────────

  defp v1_statements(prefix, p) do
    [tables(p), constraints(prefix, p), indexes(p)]
  end

  # Columns, types, defaults and order as core's V135 baseline creates them.
  defp tables(p) do
    [
      """
      CREATE TABLE IF NOT EXISTS #{p}phoenix_kit_referral_codes (
        "code" character varying(255) NOT NULL,
        "description" character varying(255) NOT NULL,
        "status" boolean DEFAULT true NOT NULL,
        "number_of_uses" integer DEFAULT 0 NOT NULL,
        "max_uses" integer NOT NULL,
        "date_created" timestamp with time zone DEFAULT now() NOT NULL,
        "expiration_date" timestamp with time zone,
        "uuid" uuid DEFAULT #{p}uuid_generate_v7() NOT NULL,
        "created_by_uuid" uuid NOT NULL,
        "beneficiary_uuid" uuid
      )
      """,
      """
      CREATE TABLE IF NOT EXISTS #{p}phoenix_kit_referral_code_usage (
        "date_used" timestamp with time zone DEFAULT now() NOT NULL,
        "uuid" uuid DEFAULT #{p}uuid_generate_v7() NOT NULL,
        "used_by_uuid" uuid NOT NULL,
        "code_uuid" uuid NOT NULL
      )
      """
    ]
  end

  # Core's V135 constraint names.
  defp constraints(prefix, p) do
    [
      guarded_constraint(
        prefix,
        "phoenix_kit_referral_codes",
        "phoenix_kit_referral_codes_pkey",
        "ALTER TABLE #{p}phoenix_kit_referral_codes ADD CONSTRAINT phoenix_kit_referral_codes_pkey PRIMARY KEY (uuid)"
      ),
      guarded_constraint(
        prefix,
        "phoenix_kit_referral_code_usage",
        "phoenix_kit_referral_code_usage_pkey",
        "ALTER TABLE #{p}phoenix_kit_referral_code_usage ADD CONSTRAINT phoenix_kit_referral_code_usage_pkey PRIMARY KEY (uuid)"
      ),
      guarded_constraint(
        prefix,
        "phoenix_kit_referral_code_usage",
        "fk_referral_code_usage_code_uuid",
        "ALTER TABLE #{p}phoenix_kit_referral_code_usage ADD CONSTRAINT fk_referral_code_usage_code_uuid FOREIGN KEY (code_uuid) REFERENCES #{p}phoenix_kit_referral_codes(uuid) ON DELETE CASCADE"
      )
    ]
  end

  # Index names are core's. They stay bare on CREATE (an index lives in its
  # table's schema).
  defp indexes(p) do
    [
      "CREATE INDEX IF NOT EXISTS phoenix_kit_referral_codes_beneficiary_uuid_idx ON #{p}phoenix_kit_referral_codes USING btree (beneficiary_uuid)",
      "CREATE UNIQUE INDEX IF NOT EXISTS phoenix_kit_referral_codes_code_uidx ON #{p}phoenix_kit_referral_codes USING btree (code)",
      "CREATE INDEX IF NOT EXISTS phoenix_kit_referral_codes_created_by_uuid_idx ON #{p}phoenix_kit_referral_codes USING btree (created_by_uuid)",
      "CREATE UNIQUE INDEX IF NOT EXISTS phoenix_kit_referral_codes_uuid_idx ON #{p}phoenix_kit_referral_codes USING btree (uuid)",
      "CREATE INDEX IF NOT EXISTS phoenix_kit_referral_code_usage_code_uuid_idx ON #{p}phoenix_kit_referral_code_usage USING btree (code_uuid)",
      "CREATE INDEX IF NOT EXISTS phoenix_kit_referral_code_usage_date_used_idx ON #{p}phoenix_kit_referral_code_usage USING btree (date_used)",
      "CREATE INDEX IF NOT EXISTS phoenix_kit_referral_code_usage_used_by_uuid_idx ON #{p}phoenix_kit_referral_code_usage USING btree (used_by_uuid)",
      "CREATE UNIQUE INDEX IF NOT EXISTS phoenix_kit_referral_code_usage_uuid_idx ON #{p}phoenix_kit_referral_code_usage USING btree (uuid)"
    ]
  end

  defp guarded_constraint(prefix, table, constraint_name, add_sql) do
    """
    DO $$
    BEGIN
      IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint c
        JOIN pg_class t ON t.oid = c.conrelid
        JOIN pg_namespace n ON n.oid = t.relnamespace
        WHERE c.conname = '#{constraint_name}'
          AND t.relname = '#{table}'
          AND n.nspname = '#{prefix}'
      ) THEN
        #{add_sql};
      END IF;
    END
    $$
    """
  end

  defp marker_query do
    """
    SELECT d.description
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    LEFT JOIN pg_description d
      ON d.objoid = c.oid AND d.objsubid = 0 AND d.classoid = 'pg_class'::regclass
    WHERE n.nspname = $1 AND c.relname = '#{@version_table}' AND c.relkind = 'r'
    """
  end

  defp marker_to_version([@marker_prefix <> n]) do
    case Integer.parse(n) do
      {v, ""} when v >= 0 -> v
      _ -> 0
    end
  end

  defp marker_to_version(_), do: 0

  defp validated_prefix(opts) do
    prefix =
      case opts do
        opts when is_list(opts) -> Keyword.get(opts, :prefix) || "public"
        %{prefix: prefix} when is_binary(prefix) -> prefix
        _ -> "public"
      end

    # Interpolated into DDL and into the guard blocks' string literals.
    unless prefix =~ ~r/^[a-zA-Z_][a-zA-Z0-9_]*$/ do
      raise ArgumentError, "invalid schema prefix: #{inspect(prefix)}"
    end

    prefix
  end
end
