defmodule PhoenixKitReferrals do
  @moduledoc """
  Referral code system for PhoenixKit - complete management in a single module.

  This module provides both the Ecto schema definition and business logic for
  managing referral codes. It includes code creation, validation, usage tracking,
  and system configuration.

  ## Schema Fields

  - `code`: The referral code string (unique, required, stored upcased)
  - `description`: Human-readable description of the code
  - `status`: Boolean indicating if the code is active
  - `number_of_uses`: Times the code has been used. Maintained by `use_code/2`;
    not settable through `changeset/2`
  - `max_uses`: Maximum number of times the code can be used
  - `created_by_uuid`: UUID of the admin who created the code
  - `beneficiary_uuid`: UUID of the user who benefits when this code is used (optional)
  - `date_created`: When the code was created
  - `expiration_date`: When the code expires (`nil` = never expires)

  ## Core Functions

  ### Code Management
  - `list_codes/0` - Get all referral codes
  - `get_code/1` - Get a referral code by UUID (`nil` if not found)
  - `get_code!/1` - Get a referral code by UUID (raises if not found)
  - `get_code_by_string/1` - Get a referral code by its string value (case-insensitive)
  - `create_code/1` - Create a new referral code
  - `update_code/2` - Update an existing referral code
  - `delete_code/1` - Delete a referral code
  - `generate_random_code/0` - Generate a random code string
  - `generate_unique_code/1` - Generate a random code no existing code holds

  ### Usage Tracking
  - `use_code/2` - Atomically claim one use of a code and record it
  - `get_usage_stats/1` - Get usage statistics for a code
  - `list_usage_for_code/1` - Get all usage records for a code
  - `user_used_code?/2` - Check if user has used a specific code

  ### System Settings
  - `enabled?/0` - Check if referral codes system is enabled
  - `required?/0` - Check if referral codes are required for registration
  - `enable_system/0` - Enable the referral codes system
  - `disable_system/0` - Disable the referral codes system
  - `set_required/1` - Set whether referral codes are required

  ## Usage Examples

      # Check if system is enabled
      if PhoenixKitReferrals.enabled?() do
        # System is active
      end

      # Create a new referral code
      {:ok, code} = PhoenixKitReferrals.create_code(%{
        code: "WELCOME2024",
        description: "Welcome promotion",
        max_uses: 100,
        created_by_uuid: admin_user.uuid,
        expiration_date: ~U[2024-12-31 23:59:59.000000Z]
      })

      # Use a referral code during registration
      case PhoenixKitReferrals.use_code("WELCOME2024", user_uuid) do
        {:ok, usage} -> # Code used successfully
        {:error, reason} -> # Handle error
      end
  """

  use Ecto.Schema
  use PhoenixKit.SchemaPrefix
  use PhoenixKit.Module
  # Gettext macros bound to the module's own catalogs, for the permission
  # metadata label/description (resolved at call time = render time).
  use Gettext, backend: PhoenixKitReferrals.Gettext

  import Ecto.Changeset
  import Ecto.Query, warn: false

  alias PhoenixKit.Dashboard.Tab
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Date, as: UtilsDate
  alias PhoenixKit.Utils.UUID, as: UUIDUtils
  alias PhoenixKitReferrals.ReferralCodeUsage
  @primary_key {:uuid, UUIDv7, autogenerate: true}

  # Alphabet for generated codes: uppercase letters + digits, minus the glyphs
  # that read alike in most fonts (0/O, 1/I).
  @code_alphabet ~c"ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
  @code_length 5

  # Named by core's V04 migration, which does NOT use Ecto's default index name.
  # Passing it explicitly is what makes `unique_constraint/3` actually catch the
  # violation instead of letting Postgrex raise.
  @code_unique_index :phoenix_kit_referral_codes_code_uidx

  schema "phoenix_kit_referral_codes" do
    field(:code, :string)
    field(:description, :string)
    field(:status, :boolean, default: true)
    field(:number_of_uses, :integer, default: 0)
    field(:max_uses, :integer)
    field(:created_by_uuid, UUIDv7)
    field(:beneficiary_uuid, UUIDv7)
    field(:date_created, :utc_datetime)
    field(:expiration_date, :utc_datetime)

    belongs_to(:creator, PhoenixKit.Users.Auth.User,
      foreign_key: :created_by_uuid,
      references: :uuid,
      define_field: false,
      type: UUIDv7
    )

    belongs_to(:beneficiary_user, PhoenixKit.Users.Auth.User,
      foreign_key: :beneficiary_uuid,
      references: :uuid,
      define_field: false,
      type: UUIDv7
    )

    has_many(:usage_records, ReferralCodeUsage, foreign_key: :code_uuid, references: :uuid)
  end

  ## --- Schema Functions ---

  @doc """
  Creates a changeset for referral code creation and admin edits.

  The code string is trimmed and upcased before validation, so codes are stored
  in one canonical case.

  Validations that constrain a *value being set* — `expiration_date` in the
  future, `max_uses` within the system limit — run only when that field is
  actually changing. An already-expired code, or a code whose `max_uses` predates
  a lowered system limit, therefore remains editable: an admin can still
  deactivate it, rename it, or fix its description.

  The usage counter is not castable here. It is owned by `use_code/2`, which
  increments it atomically.
  """
  def changeset(referral_code, attrs) do
    referral_code
    |> cast(attrs, [
      :code,
      :description,
      :status,
      :max_uses,
      :created_by_uuid,
      :beneficiary_uuid,
      :date_created,
      :expiration_date
    ])
    |> update_change(:code, &normalize_code/1)
    |> validate_required([:code, :description, :max_uses])
    |> validate_length(:code, min: 3, max: 50)
    |> validate_length(:description, min: 1, max: 255)
    |> validate_number(:max_uses, greater_than: 0)
    |> validate_max_uses_limit()
    |> validate_expiration_date()
    |> validate_code_available()
    |> unique_constraint(:code, name: @code_unique_index)
    |> maybe_set_date_created()
  end

  @doc """
  Generates a random #{@code_length}-character alphanumeric referral code.

  Returns a string of uppercase letters and digits, excluding the characters
  that read alike in most fonts (`0`, `O`, `I`, `1`). Characters are drawn with
  replacement, so a code may repeat a character.

  This does not check the code against existing codes — see
  `generate_unique_code/1`.

  ## Examples

      iex> PhoenixKitReferrals.generate_random_code()
      "A7B2K"
  """
  def generate_random_code do
    for _ <- 1..@code_length, into: "", do: <<Enum.random(@code_alphabet)>>
  end

  @doc """
  Generates a random code that no existing referral code already holds.

  Retries up to `attempts` times before giving up, so a caller never has to
  handle a unique-constraint violation from a generated code.

  ## Examples

      iex> PhoenixKitReferrals.generate_unique_code()
      {:ok, "A7B2K"}
  """
  def generate_unique_code(attempts \\ 10) when is_integer(attempts) and attempts > 0 do
    Enum.reduce_while(1..attempts, {:error, :no_unique_code}, fn _attempt, exhausted ->
      code = generate_random_code()

      case get_code_by_string(code) do
        nil -> {:halt, {:ok, code}}
        %__MODULE__{} -> {:cont, exhausted}
      end
    end)
  end

  @doc """
  Checks if a referral code is currently valid for use.

  A code is valid if:
  - It is active (status: true)
  - It has not exceeded its maximum uses
  - It has not expired (a code with no `expiration_date` never expires)

  ## Examples

      iex> PhoenixKitReferrals.valid_for_use?(code)
      true
  """
  def valid_for_use?(%__MODULE__{} = code) do
    code.status and code.number_of_uses < code.max_uses and not expired?(code)
  end

  @doc """
  Checks if a referral code has expired.

  A code with no `expiration_date` never expires.

  ## Examples

      iex> PhoenixKitReferrals.expired?(code)
      false
  """
  def expired?(%__MODULE__{expiration_date: nil}), do: false

  def expired?(%__MODULE__{expiration_date: expiration_date}) do
    not DateTime.after?(expiration_date, UtilsDate.utc_now())
  end

  @doc """
  Checks if a referral code has reached its usage limit.

  ## Examples

      iex> PhoenixKitReferrals.usage_limit_reached?(code)
      false
  """
  def usage_limit_reached?(%__MODULE__{} = code) do
    code.number_of_uses >= code.max_uses
  end

  ## --- Business Logic Functions ---

  @doc """
  Returns the list of referral codes ordered by creation date.

  ## Examples

      iex> PhoenixKitReferrals.list_codes()
      [%PhoenixKitReferrals{}, ...]
  """
  def list_codes do
    __MODULE__
    |> order_by([r], desc: r.date_created)
    |> preload([:creator, :beneficiary_user])
    |> repo().all()
  end

  @doc """
  Gets a single referral code by UUID.

  Returns the referral code if found. Any input that is not a well-formed UUID
  string — including an integer id — returns `nil`.

  ## Examples

      iex> PhoenixKitReferrals.get_code("550e8400-e29b-41d4-a716-446655440000")
      %PhoenixKitReferrals{}

      iex> PhoenixKitReferrals.get_code("00000000-0000-0000-0000-000000000000")
      nil

      iex> PhoenixKitReferrals.get_code(123)
      nil
  """
  def get_code(id) when is_binary(id) do
    if UUIDUtils.valid?(id) do
      repo().get_by(__MODULE__, uuid: id)
    else
      nil
    end
  end

  def get_code(_), do: nil

  @doc """
  Same as `get_code/1`, but raises `Ecto.NoResultsError` if the code does not exist.

  ## Examples

      iex> PhoenixKitReferrals.get_code!("550e8400-e29b-41d4-a716-446655440000")
      %PhoenixKitReferrals{}

      iex> PhoenixKitReferrals.get_code!("00000000-0000-0000-0000-000000000000")
      ** (Ecto.NoResultsError)
  """
  def get_code!(id) do
    case get_code(id) do
      nil -> raise Ecto.NoResultsError, queryable: __MODULE__
      code -> code
    end
  end

  @doc """
  Gets a single referral code by its string value.

  The lookup trims and ignores case, so a user who types their code in lowercase
  still matches. Returns the referral code if found, `nil` otherwise.

  ## Examples

      iex> PhoenixKitReferrals.get_code_by_string("WELCOME2024")
      %PhoenixKitReferrals{}

      iex> PhoenixKitReferrals.get_code_by_string(" welcome2024 ")
      %PhoenixKitReferrals{}

      iex> PhoenixKitReferrals.get_code_by_string("INVALID")
      nil
  """
  def get_code_by_string(code_string) when is_binary(code_string) do
    normalized = normalize_code(code_string)

    # `limit: 1` keeps `one/1` total: rows predating case normalization could
    # differ only by case, and the unique index is on the raw `code` column.
    from(r in __MODULE__,
      where: fragment("upper(?)", r.code) == ^normalized,
      order_by: [asc: r.date_created],
      limit: 1
    )
    |> repo().one()
  end

  @doc """
  Creates a referral code.

  ## Examples

      iex> PhoenixKitReferrals.create_code(%{code: "TEST123", max_uses: 10})
      {:ok, %PhoenixKitReferrals{}}

      iex> PhoenixKitReferrals.create_code(%{code: ""})
      {:error, %Ecto.Changeset{}}
  """
  def create_code(attrs \\ %{}) do
    %__MODULE__{}
    |> changeset(attrs)
    |> repo().insert()
  end

  @doc """
  Updates a referral code.

  ## Examples

      iex> PhoenixKitReferrals.update_code(code, %{description: "Updated"})
      {:ok, %PhoenixKitReferrals{}}

      iex> PhoenixKitReferrals.update_code(code, %{code: ""})
      {:error, %Ecto.Changeset{}}
  """
  def update_code(%__MODULE__{} = referral_code, attrs) do
    referral_code
    |> changeset(attrs)
    |> repo().update()
  end

  @doc """
  Deletes a referral code.

  ## Examples

      iex> PhoenixKitReferrals.delete_code(code)
      {:ok, %PhoenixKitReferrals{}}

      iex> PhoenixKitReferrals.delete_code(code)
      {:error, %Ecto.Changeset{}}
  """
  def delete_code(%__MODULE__{} = referral_code) do
    repo().delete(referral_code)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking referral code changes.

  ## Examples

      iex> PhoenixKitReferrals.change_code(code)
      %Ecto.Changeset{data: %PhoenixKitReferrals{}}
  """
  def change_code(%__MODULE__{} = referral_code, attrs \\ %{}) do
    changeset(referral_code, attrs)
  end

  @doc """
  Records usage of a referral code by a user.

  Claims one use of the code and writes the matching usage record in a single
  transaction. The claim is a conditional `UPDATE` that re-checks status,
  expiration, and the usage limit in the database, so two concurrent callers can
  never push a code past its `max_uses`.

  A user may use a given code only once; a repeat attempt returns
  `{:error, :already_used}` and leaves the counter untouched.

  ## Examples

      iex> PhoenixKitReferrals.use_code("WELCOME2024", user_uuid)
      {:ok, %PhoenixKitReferrals.ReferralCodeUsage{}}

      iex> PhoenixKitReferrals.use_code("NOSUCHCODE", user_uuid)
      {:error, :code_not_found}

      iex> PhoenixKitReferrals.use_code("EXPIRED", user_uuid)
      {:error, :code_expired}
  """
  def use_code(code_string, user_uuid) when is_binary(code_string) and is_binary(user_uuid) do
    if UUIDUtils.valid?(user_uuid) do
      case get_code_by_string(code_string) do
        nil -> {:error, :code_not_found}
        code -> record_code_usage(code, user_uuid)
      end
    else
      {:error, :invalid_user_uuid}
    end
  end

  defp record_code_usage(code, user_uuid) do
    repo().transaction(fn ->
      with :ok <- claim_use(code.uuid),
           :ok <- ensure_unused_by(code.uuid, user_uuid),
           {:ok, usage} <- insert_usage(code.uuid, user_uuid) do
        usage
      else
        {:error, reason} -> repo().rollback(reason)
      end
    end)
  end

  # Increments the counter only if the code is still claimable, atomically.
  # The row lock this takes also serializes concurrent `use_code/2` calls on the
  # same code, which is what makes the duplicate check below sound without a
  # unique index on (code_uuid, used_by_uuid) — core owns that table's DDL.
  defp claim_use(code_uuid) do
    now = UtilsDate.utc_now()

    query =
      from(r in __MODULE__,
        where: r.uuid == ^code_uuid,
        where: r.status == true,
        where: r.number_of_uses < r.max_uses,
        where: is_nil(r.expiration_date) or r.expiration_date > ^now,
        update: [inc: [number_of_uses: 1]]
      )

    case repo().update_all(query, []) do
      {1, _} -> :ok
      {0, _} -> {:error, rejection_reason(code_uuid)}
    end
  end

  # The claim failed. Re-read the row (now that we've observed the committed
  # state) to say *why*.
  defp rejection_reason(code_uuid) do
    case repo().get(__MODULE__, code_uuid) do
      nil -> :code_not_found
      code -> code_error(code)
    end
  end

  defp code_error(code) do
    cond do
      not code.status -> :code_inactive
      expired?(code) -> :code_expired
      usage_limit_reached?(code) -> :usage_limit_reached
      true -> :code_invalid
    end
  end

  defp ensure_unused_by(code_uuid, user_uuid) do
    if user_used_code?(user_uuid, code_uuid), do: {:error, :already_used}, else: :ok
  end

  defp insert_usage(code_uuid, user_uuid) do
    %ReferralCodeUsage{}
    |> ReferralCodeUsage.changeset(%{code_uuid: code_uuid, used_by_uuid: user_uuid})
    |> repo().insert()
  end

  @doc """
  Gets usage statistics for a referral code.

  ## Examples

      iex> PhoenixKitReferrals.get_usage_stats(code_uuid)
      %{total_uses: 5, unique_users: 3, last_used: ~U[...], recent_users: [...]}
  """
  def get_usage_stats(code_uuid) when is_binary(code_uuid) do
    ReferralCodeUsage.get_usage_stats(code_uuid)
  end

  @doc """
  Lists all usage records for a referral code.

  ## Examples

      iex> PhoenixKitReferrals.list_usage_for_code(code_uuid)
      [%PhoenixKitReferrals.ReferralCodeUsage{}, ...]
  """
  def list_usage_for_code(code_uuid) when is_binary(code_uuid) do
    ReferralCodeUsage.for_code(code_uuid)
    |> repo().all()
  end

  @doc """
  Checks if a user has already used a specific referral code.

  ## Examples

      iex> PhoenixKitReferrals.user_used_code?(user_uuid, code_uuid)
      false
  """
  def user_used_code?(user_uuid, code_uuid) when is_binary(user_uuid) and is_binary(code_uuid) do
    ReferralCodeUsage.user_used_code?(user_uuid, code_uuid)
  end

  ## --- System Settings ---

  @impl PhoenixKit.Module
  @doc """
  Checks if the referral codes system is enabled.

  Returns true if the "referral_codes_enabled" setting is true. Any error
  (e.g. the database not being available yet at startup) is rescued and
  treated as disabled, so callers never need to special-case boot ordering.

  ## Examples

      iex> PhoenixKitReferrals.enabled?()
      false
  """
  def enabled? do
    Settings.get_boolean_setting("referral_codes_enabled", false)
  rescue
    _ -> false
  end

  @doc """
  Checks if referral codes are required for user registration.

  Returns true if the "referral_codes_required" setting is true.

  ## Examples

      iex> PhoenixKitReferrals.required?()
      false
  """
  def required? do
    Settings.get_boolean_setting("referral_codes_required", false)
  end

  @impl PhoenixKit.Module
  @doc """
  Enables the referral codes system.

  Sets the "referral_codes_enabled" setting to true.

  ## Examples

      iex> PhoenixKitReferrals.enable_system()
      {:ok, %Setting{}}
  """
  def enable_system do
    Settings.update_boolean_setting_with_module("referral_codes_enabled", true, "referral_codes")
  end

  @impl PhoenixKit.Module
  @doc """
  Disables the referral codes system.

  Sets the "referral_codes_enabled" setting to false.

  ## Examples

      iex> PhoenixKitReferrals.disable_system()
      {:ok, %Setting{}}
  """
  def disable_system do
    Settings.update_boolean_setting_with_module("referral_codes_enabled", false, "referral_codes")
  end

  @doc """
  Sets whether referral codes are required for registration.

  ## Examples

      iex> PhoenixKitReferrals.set_required(true)
      {:ok, %Setting{}}

      iex> PhoenixKitReferrals.set_required(false)
      {:ok, %Setting{}}
  """
  def set_required(required) when is_boolean(required) do
    Settings.update_boolean_setting_with_module(
      "referral_codes_required",
      required,
      "referral_codes"
    )
  end

  @doc """
  Gets the maximum number of uses allowed per referral code.

  Returns the system-wide limit for how many times a single referral code can be used.
  Defaults to 100 if not set.

  ## Examples

      iex> PhoenixKitReferrals.get_max_uses_per_code()
      100
  """
  def get_max_uses_per_code do
    Settings.get_integer_setting("max_number_of_uses_per_code", 100)
  end

  @doc """
  Gets the maximum number of referral codes a single user can create.

  Returns the system-wide limit for referral code creation per user.
  Defaults to 10 if not set.

  ## Examples

      iex> PhoenixKitReferrals.get_max_codes_per_user()
      10
  """
  def get_max_codes_per_user do
    Settings.get_integer_setting("max_number_of_codes_per_user", 10)
  end

  @doc """
  Sets the maximum number of uses allowed per referral code.

  Updates the system-wide limit for referral code usage.

  ## Examples

      iex> PhoenixKitReferrals.set_max_uses_per_code(50)
      {:ok, %Setting{}}
  """
  def set_max_uses_per_code(max_uses) when is_integer(max_uses) and max_uses > 0 do
    Settings.update_setting_with_module(
      "max_number_of_uses_per_code",
      to_string(max_uses),
      "referral_codes"
    )
  end

  @doc """
  Sets the maximum number of referral codes a single user can create.

  Updates the system-wide limit for referral code creation per user.

  ## Examples

      iex> PhoenixKitReferrals.set_max_codes_per_user(5)
      {:ok, %Setting{}}
  """
  def set_max_codes_per_user(max_codes) when is_integer(max_codes) and max_codes > 0 do
    Settings.update_setting_with_module(
      "max_number_of_codes_per_user",
      to_string(max_codes),
      "referral_codes"
    )
  end

  @impl PhoenixKit.Module
  @doc """
  Gets the current referral codes system configuration.

  Returns a map with the current settings.

  ## Examples

      iex> PhoenixKitReferrals.get_config()
      %{enabled: false, required: false}
  """
  def get_config do
    %{
      enabled: enabled?(),
      required: required?(),
      max_uses_per_code: get_max_uses_per_code(),
      max_codes_per_user: get_max_codes_per_user()
    }
  end

  # ============================================================================
  # Module Behaviour Callbacks
  # ============================================================================

  @impl PhoenixKit.Module
  def module_key, do: "referrals"

  @impl PhoenixKit.Module
  def module_name, do: "Referrals"

  @impl PhoenixKit.Module
  @doc "Module version, shown on the admin Modules page. Keep in sync with `mix.exs`."
  def version, do: "0.4.0"

  @impl PhoenixKit.Module
  def permission_metadata do
    %{
      key: "referrals",
      label: gettext("Referrals"),
      icon: "hero-gift",
      description: gettext("Referrals, tracking, and reward programs")
    }
  end

  @impl PhoenixKit.Module
  def admin_tabs do
    [
      # Top-level section (mirrors phoenix_kit_ai's :admin_ai). Kept separate
      # from :admin_users on purpose: unlike user management, this is a
      # module we intend to open up to non-Owner/Admin roles that only hold
      # the "referrals" permission, so it can't live inside a parent section
      # gated on full user-management access.
      Tab.new!(
        id: :admin_referrals,
        label: "Referrals",
        icon: "hero-gift",
        # Not a real page — Overview and Codes below are true siblings, so
        # the parent link redirects to whichever has lower priority
        # (mirrors phoenix_kit_ai's :admin_ai).
        path: "referral-codes",
        priority: 600,
        level: :admin,
        permission: "referrals",
        match: :prefix,
        group: :admin_modules,
        subtab_display: :when_active,
        highlight_with_subtabs: false,
        redirect_to_first_subtab: true,
        gettext_backend: PhoenixKitReferrals.Gettext
      ),
      Tab.new!(
        id: :admin_referrals_overview,
        label: "Overview",
        icon: "hero-chart-bar",
        # Sibling of Codes below, deliberately NOT nested under it (or vice
        # versa) — either nesting would make prefix-based active-tab
        # matching highlight both tabs at once for one of the two pages.
        path: "referral-codes/overview",
        priority: 601,
        level: :admin,
        parent: :admin_referrals,
        permission: "referrals",
        gettext_backend: PhoenixKitReferrals.Gettext
      ),
      Tab.new!(
        id: :admin_referrals_codes,
        label: "Codes",
        icon: "hero-ticket",
        # No "users/" segment — this module has its own top-level section,
        # not nested under Admin > Users.
        path: "referral-codes/codes",
        priority: 602,
        level: :admin,
        parent: :admin_referrals,
        permission: "referrals",
        gettext_backend: PhoenixKitReferrals.Gettext
      )
    ]
  end

  @impl PhoenixKit.Module
  def settings_tabs do
    [
      Tab.new!(
        id: :admin_settings_referrals,
        label: "Referrals",
        icon: "hero-gift",
        path: "referral-codes",
        priority: 920,
        level: :admin,
        parent: :admin_settings,
        permission: "referrals",
        gettext_backend: PhoenixKitReferrals.Gettext
      )
    ]
  end

  @impl PhoenixKit.Module
  def route_module, do: PhoenixKitReferrals.Routes

  @impl PhoenixKit.Module
  @doc "OTP apps whose templates Tailwind should scan for CSS classes."
  def css_sources, do: [:phoenix_kit_referrals]

  # No `@impl` on purpose — older core releases don't declare the `js_sources/0`
  # callback, and annotating it would warn (and fail `--warnings-as-errors`).
  # Core's `:phoenix_kit_js_sources` compiler folds this into the host's module
  # JS bundle where present. (Mirrors `phoenix_kit_crm`.)
  @doc """
  Ships the referral-link capture script (URL `?referral=` -> localStorage ->
  auto-filled `referral_code` field / OAuth links) via PhoenixKit's JS bundle
  extension point.
  """
  def js_sources do
    [
      %{
        app: :phoenix_kit_referrals,
        file: "static/assets/phoenix_kit_referrals.js",
        global: "PhoenixKitReferralsHooks"
      }
    ]
  end

  @doc """
  Gets codes that are currently valid for use.

  Returns codes that are active, not expired, and haven't reached usage limits.
  Mirrors `valid_for_use?/1`, including codes with no `expiration_date` — those
  never expire.

  ## Examples

      iex> PhoenixKitReferrals.list_valid_codes()
      [%PhoenixKitReferrals{}, ...]
  """
  def list_valid_codes do
    now = UtilsDate.utc_now()

    from(r in __MODULE__,
      where: r.status == true,
      where: is_nil(r.expiration_date) or r.expiration_date > ^now,
      where: r.number_of_uses < r.max_uses,
      order_by: [desc: r.date_created]
    )
    |> repo().all()
  end

  @doc """
  Gets summary statistics for the referral codes system.

  Returns counts and metrics useful for admin dashboards.

  ## Examples

      iex> PhoenixKitReferrals.get_system_stats()
      %{total_codes: 10, active_codes: 8, total_usage: 150, codes_with_usage: 6}
  """
  def get_system_stats do
    codes_query = from(r in __MODULE__)
    usage_query = from(u in ReferralCodeUsage)

    total_codes = repo().aggregate(codes_query, :count)
    active_codes = repo().aggregate(from(r in codes_query, where: r.status == true), :count)
    total_usage = repo().aggregate(usage_query, :count)

    codes_with_usage =
      repo().aggregate(from(r in codes_query, where: r.number_of_uses > 0), :count)

    %{
      total_codes: total_codes,
      active_codes: active_codes,
      total_usage: total_usage,
      codes_with_usage: codes_with_usage
    }
  end

  @doc """
  Gets the codes with the most recorded uses, for an admin leaderboard.

  Only codes with at least one use are returned. Preloads `:creator` and
  `:beneficiary_user` for display.

  ## Examples

      iex> PhoenixKitReferrals.top_codes(5)
      [%PhoenixKitReferrals{}, ...]
  """
  def top_codes(limit \\ 5) when is_integer(limit) and limit > 0 do
    from(r in __MODULE__,
      where: r.number_of_uses > 0,
      order_by: [desc: r.number_of_uses],
      limit: ^limit,
      preload: [:creator, :beneficiary_user]
    )
    |> repo().all()
  end

  @doc """
  Gets the most recent referral code usage records system-wide, for an admin
  activity feed.

  ## Examples

      iex> PhoenixKitReferrals.list_recent_usage(10)
      [%PhoenixKitReferrals.ReferralCodeUsage{}, ...]
  """
  def list_recent_usage(limit \\ 10) when is_integer(limit) and limit > 0 do
    ReferralCodeUsage.recent(limit)
    |> repo().all()
  end

  ## --- Private Helpers ---

  defp normalize_code(code) when is_binary(code), do: code |> String.trim() |> String.upcase()

  # A friendlier duplicate message than the constraint error, checked only when
  # the code is actually changing. `unique_constraint/3` remains the enforcer:
  # this read is advisory and can lose a race.
  defp validate_code_available(%Ecto.Changeset{valid?: false} = changeset), do: changeset

  defp validate_code_available(changeset) do
    case get_change(changeset, :code) do
      nil -> changeset
      code -> reject_if_taken(changeset, code)
    end
  end

  defp reject_if_taken(changeset, code) do
    case get_code_by_string(code) do
      nil ->
        changeset

      # Editing the code that already holds this string is not a conflict.
      %__MODULE__{uuid: uuid} ->
        if uuid == changeset.data.uuid do
          changeset
        else
          add_error(changeset, :code, "has already been taken")
        end
    end
  end

  # Only guards an expiration being *set*. A code that has already expired stays
  # editable, so an admin can still deactivate or amend it.
  defp validate_expiration_date(changeset) do
    case get_change(changeset, :expiration_date) do
      nil ->
        changeset

      expiration_date ->
        if DateTime.after?(expiration_date, UtilsDate.utc_now()) do
          changeset
        else
          add_error(changeset, :expiration_date, "must be in the future")
        end
    end
  end

  defp maybe_set_date_created(changeset) do
    if changeset.data.__meta__.state == :built do
      put_change(changeset, :date_created, UtilsDate.utc_now())
    else
      changeset
    end
  end

  # Only guards a max_uses being *set*. Lowering the system limit must not strand
  # existing codes that were created under a higher one — they stay editable and
  # usable, they just can't be raised further.
  defp validate_max_uses_limit(changeset) do
    case get_change(changeset, :max_uses) do
      nil ->
        changeset

      max_uses ->
        system_limit = get_max_uses_per_code()

        if max_uses <= system_limit do
          changeset
        else
          add_error(changeset, :max_uses, "cannot exceed system limit of #{system_limit}")
        end
    end
  end

  @doc """
  Validates that a user hasn't exceeded their referral code creation limit.

  Checks the current number of codes created by the user against the system limit.
  Returns `{:ok, :valid}` if within limits, `{:error, reason}` if limit exceeded.

  ## Examples

      iex> PhoenixKitReferrals.validate_user_code_limit(1)
      {:ok, :valid}

      iex> PhoenixKitReferrals.validate_user_code_limit(1)
      {:error, "You have reached the maximum limit of 10 referral codes"}
  """
  def validate_user_code_limit(user_uuid) when is_binary(user_uuid) do
    max_codes = get_max_codes_per_user()
    current_count = count_user_codes(user_uuid)

    if current_count < max_codes do
      {:ok, :valid}
    else
      {:error, "You have reached the maximum limit of #{max_codes} referral codes"}
    end
  end

  @doc """
  Counts the total number of referral codes created by a user.

  ## Examples

      iex> PhoenixKitReferrals.count_user_codes(1)
      5
  """
  def count_user_codes(user_uuid) when is_binary(user_uuid) do
    if UUIDUtils.valid?(user_uuid) do
      from(r in __MODULE__, where: r.created_by_uuid == ^user_uuid, select: count(r.uuid))
      |> repo().one()
    else
      0
    end
  end

  # Gets the configured repository for database operations
  defp repo do
    PhoenixKit.RepoHelper.repo()
  end
end
