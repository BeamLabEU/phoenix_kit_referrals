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

      assert PhoenixKitReferrals.version() == "0.3.0"
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
    test "contributes the referral-codes tab under the Users section" do
      assert [%{} = tab] = PhoenixKitReferrals.admin_tabs()
      assert tab.id == :admin_users_referral_codes
      assert tab.parent == :admin_users
      assert tab.permission == "referrals"
      assert tab.level == :admin
      # No live_view — routes come from route_module/0.
      assert tab.live_view == nil
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
      past = DateTime.add(DateTime.utc_now(), -3600, :second)
      assert PhoenixKitReferrals.expired?(%PhoenixKitReferrals{expiration_date: past})
    end
  end
end
