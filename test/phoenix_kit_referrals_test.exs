defmodule PhoenixKitReferralsTest do
  use ExUnit.Case, async: true

  describe "behaviour implementation" do
    test "implements PhoenixKit.Module" do
      behaviours =
        PhoenixKitReferrals.__info__(:attributes)
        |> Keyword.get_values(:behaviour)
        |> List.flatten()

      assert PhoenixKit.Module in behaviours
    end

    test "has @phoenix_kit_module attribute for auto-discovery" do
      attrs = PhoenixKitReferrals.__info__(:attributes)
      assert Keyword.get(attrs, :phoenix_kit_module) == [true]
    end
  end

  describe "required callbacks" do
    test "module_key/0 returns \"referrals\"" do
      assert PhoenixKitReferrals.module_key() == "referrals"
    end

    test "module_name/0 returns \"Referrals\"" do
      assert PhoenixKitReferrals.module_name() == "Referrals"
    end

    test "enabled?/enable_system/disable_system are exported" do
      assert function_exported?(PhoenixKitReferrals, :enabled?, 0)
      assert function_exported?(PhoenixKitReferrals, :enable_system, 0)
      assert function_exported?(PhoenixKitReferrals, :disable_system, 0)
    end
  end

  describe "version/0" do
    test "matches the package version declared in mix.exs" do
      vsn = :phoenix_kit_referrals |> Application.spec(:vsn) |> to_string()

      assert PhoenixKitReferrals.version() == "0.4.0"
      assert PhoenixKitReferrals.version() == vsn
    end
  end

  describe "css_sources/0" do
    test "lists this module's OTP app so Tailwind scans its templates" do
      assert PhoenixKitReferrals.css_sources() == [:phoenix_kit_referrals]
    end
  end

  describe "js_sources/0" do
    test "ships the referral-capture bundle for the host's JS hook aggregate" do
      assert [%{app: app, file: file, global: global}] = PhoenixKitReferrals.js_sources()

      assert app == :phoenix_kit_referrals
      assert file == "static/assets/phoenix_kit_referrals.js"
      assert global == "PhoenixKitReferralsHooks"
      assert File.exists?(Path.join(:code.priv_dir(:phoenix_kit_referrals), file))
    end
  end

  describe "permission_metadata/0" do
    test "returns a map with required fields, keyed by module_key" do
      assert %{key: key, label: label, icon: icon, description: desc} =
               PhoenixKitReferrals.permission_metadata()

      assert key == PhoenixKitReferrals.module_key()
      assert is_binary(label) and label != ""
      assert String.starts_with?(icon, "hero-")
      assert is_binary(desc) and desc != ""
    end
  end

  describe "admin_tabs/0" do
    test "contributes its own top-level section, not nested under Users" do
      assert [top, overview, codes] = PhoenixKitReferrals.admin_tabs()

      assert top.id == :admin_referrals
      assert top.parent == nil
      assert top.redirect_to_first_subtab == true
      refute String.contains?(top.path, "users")

      assert overview.id == :admin_referrals_overview
      assert overview.parent == :admin_referrals
      refute String.contains?(overview.path, "users")

      assert codes.id == :admin_referrals_codes
      assert codes.parent == :admin_referrals
      refute String.contains?(codes.path, "users")

      # Siblings, neither nested under the other — prefix-based active-tab
      # matching would otherwise highlight both for one of the two pages.
      refute String.starts_with?(overview.path, codes.path <> "/")
      refute String.starts_with?(codes.path, overview.path <> "/")

      for tab <- [top, overview, codes] do
        assert tab.permission == "referrals"
        assert tab.level == :admin
        # No live_view — routes come from route_module/0.
        assert tab.live_view == nil
      end
    end
  end

  describe "settings_tabs/0" do
    test "contributes the referrals settings tab under Settings" do
      assert [%{} = tab] = PhoenixKitReferrals.settings_tabs()
      assert tab.id == :admin_settings_referrals
      assert tab.parent == :admin_settings
      assert tab.permission == "referrals"
    end
  end

  describe "route_module/0" do
    test "points at the module's Routes, which exposes the admin route macros" do
      routes = PhoenixKitReferrals.route_module()
      assert routes == PhoenixKitReferrals.Routes
      # Force-load before function_exported?/3 (otherwise it depends on whether
      # the module happens to be loaded yet).
      assert Code.ensure_loaded?(routes)
      assert function_exported?(routes, :admin_routes, 0)
      assert function_exported?(routes, :admin_locale_routes, 0)
    end
  end

  describe "pure code helpers (no DB)" do
    test "generate_random_code/0 returns a 5-char string without confusing chars" do
      code = PhoenixKitReferrals.generate_random_code()
      assert is_binary(code)
      assert String.length(code) == 5
      refute String.contains?(code, ["0", "O", "I", "1"])
    end

    test "generate_random_code/0 draws with replacement, so a char can repeat" do
      # Sampling without replacement (the old Enum.take_random/2) made a repeated
      # character unreachable. ~28% of codes repeat one, so over 200 draws seeing
      # none would mean we regressed, not that we got unlucky.
      assert Enum.any?(1..200, fn _ ->
               code = PhoenixKitReferrals.generate_random_code()
               String.length(code) != code |> String.graphemes() |> Enum.uniq() |> length()
             end)
    end

    test "generate_random_code/0 draws uniformly across the whole alphabet" do
      # Guards the `rem(byte, 32)` mapping in generate_random_code/0. It is only
      # unbiased because 256 divides evenly by the alphabet size; if someone
      # changes @code_alphabet to a size that does not divide 256, the low
      # characters get drawn more often and the keyspace quietly shrinks. The
      # module has a compile-time check for that, and this is the runtime half.
      alphabet = ~c"ABCDEFGHJKLMNPQRSTUVWXYZ23456789" |> to_string() |> String.graphemes()

      chars =
        1..4000
        |> Enum.map_join("", fn _ -> PhoenixKitReferrals.generate_random_code() end)
        |> String.graphemes()

      freq = Enum.frequencies(chars)
      expected = div(length(chars), length(alphabet))

      # Every character reachable, none outside the alphabet.
      assert MapSet.new(Map.keys(freq)) == MapSet.new(alphabet)

      # Uniform within a generous band — wide enough never to flake, tight enough
      # that a biased mapping (which would roughly double some counts) fails.
      Enum.each(freq, fn {char, count} ->
        assert count > expected * 0.6,
               "#{char} drawn #{count} times, expected ~#{expected} — distribution looks biased"

        assert count < expected * 1.4,
               "#{char} drawn #{count} times, expected ~#{expected} — distribution looks biased"
      end)
    end

    test "usage_limit_reached?/1 compares uses against max" do
      refute PhoenixKitReferrals.usage_limit_reached?(%PhoenixKitReferrals{
               number_of_uses: 0,
               max_uses: 10
             })

      assert PhoenixKitReferrals.usage_limit_reached?(%PhoenixKitReferrals{
               number_of_uses: 10,
               max_uses: 10
             })
    end

    test "expired?/1 is false for a code with no expiration" do
      refute PhoenixKitReferrals.expired?(%PhoenixKitReferrals{expiration_date: nil})
    end

    test "expired?/1 is true for a code whose expiration is in the past" do
      assert PhoenixKitReferrals.expired?(%PhoenixKitReferrals{expiration_date: past()})
    end

    test "valid_for_use?/1 accepts a never-expiring code, matching list_valid_codes/0" do
      assert PhoenixKitReferrals.valid_for_use?(%PhoenixKitReferrals{
               status: true,
               number_of_uses: 0,
               max_uses: 10,
               expiration_date: nil
             })
    end

    test "valid_for_use?/1 rejects an inactive, exhausted, or expired code" do
      base = %PhoenixKitReferrals{status: true, number_of_uses: 0, max_uses: 10}

      refute PhoenixKitReferrals.valid_for_use?(%{base | status: false})
      refute PhoenixKitReferrals.valid_for_use?(%{base | number_of_uses: 10})
      refute PhoenixKitReferrals.valid_for_use?(%{base | expiration_date: past()})
    end
  end

  # These exercise changeset/2 on paths that never reach the database: the
  # uniqueness pre-check is skipped once the changeset is already invalid, and
  # the max_uses / expiration guards only fire when their field is changing.
  describe "changeset/2 (no DB)" do
    test "trims and upcases the code so lookups are case-insensitive" do
      changeset = PhoenixKitReferrals.changeset(%PhoenixKitReferrals{}, %{code: "  welcome  "})

      assert changeset.changes.code == "WELCOME"
    end

    test "does not cast number_of_uses — the counter is owned by use_code/2" do
      changeset =
        PhoenixKitReferrals.changeset(persisted_code(), %{number_of_uses: 999})

      refute Map.has_key?(changeset.changes, :number_of_uses)
    end

    test "an expired code stays editable, so an admin can still deactivate it" do
      changeset =
        persisted_code(expiration_date: past())
        |> PhoenixKitReferrals.changeset(%{status: false})

      assert changeset.valid?
      assert changeset.changes == %{status: false}
    end

    test "but setting an expiration in the past is still rejected" do
      changeset =
        persisted_code()
        |> PhoenixKitReferrals.changeset(%{expiration_date: past()})

      refute changeset.valid?
      assert %{expiration_date: ["must be in the future"]} = errors_on(changeset)
    end
  end

  defp past, do: DateTime.add(DateTime.utc_now(), -3600, :second)

  # A code as it comes back from the DB. The :loaded meta state matters —
  # changeset/2 only stamps date_created on :built structs.
  defp persisted_code(attrs \\ []) do
    defaults = [
      uuid: "018f0000-0000-7000-8000-000000000000",
      code: "WELCO",
      description: "Welcome promotion",
      status: true,
      number_of_uses: 0,
      max_uses: 10
    ]

    PhoenixKitReferrals
    |> struct(Keyword.merge(defaults, attrs))
    |> Ecto.put_meta(state: :loaded)
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), "") |> to_string()
      end)
    end)
  end
end
