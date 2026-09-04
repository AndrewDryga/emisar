defmodule EmisarWeb.RuntimeConfigTest do
  # `System.put_env/2` is global to the node, so this file cannot run concurrently.
  use ExUnit.Case, async: false

  @runtime_config Path.expand("../../../../config/runtime.exs", __DIR__)

  # Everything the prod branch reads that a test here sets, blanks, or must not
  # inherit from the developer's shell.
  @managed_vars ~w[
    SECRET_KEY_BASE DATABASE_URL EMISAR_DISABLE_BILLING EMISAR_DEV_ROUTES
    PHX_HOST FORCE_SSL POSTMARK_API_TOKEN POSTMARK_WEBHOOK_SECRET SENTRY_DSN
    MIXPANEL_TOKEN STATUS_PAGE_URL X_ADS_CONVERSIONS_JSON MAILER_FROM_EMAIL
  ]

  setup do
    saved = Map.new(@managed_vars, &{&1, System.get_env(&1)})
    Enum.each(@managed_vars, &System.delete_env/1)

    System.put_env(%{
      "SECRET_KEY_BASE" => String.duplicate("s", 64),
      "DATABASE_URL" => "ecto://user:pass@localhost/emisar_runtime_config_test",
      "EMISAR_DISABLE_BILLING" => "1"
    })

    on_exit(fn ->
      Enum.each(saved, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end)

    :ok
  end

  describe "blank optional variables count as absent" do
    test "a blank POSTMARK_API_TOKEN keeps the Logger mailer instead of a keyless Postmark" do
      System.put_env("POSTMARK_API_TOKEN", "")

      config = read_prod_config()

      assert config[:emisar][Emisar.Mailer][:adapter] == Swoosh.Adapters.Logger
    end

    test "a real POSTMARK_API_TOKEN still selects Postmark" do
      System.put_env("POSTMARK_API_TOKEN", "postmark-token")

      config = read_prod_config()

      assert config[:emisar][Emisar.Mailer][:adapter] == Swoosh.Adapters.Postmark
      assert config[:emisar][Emisar.Mailer][:api_key] == "postmark-token"
    end

    test "a blank PHX_HOST falls back to the default host rather than an empty URL" do
      System.put_env("PHX_HOST", "")

      config = read_prod_config()

      assert config[:emisar][:public_url][:host] == "emisar.dev"
    end

    test "a blank FORCE_SSL keeps the HTTPS-fronted default" do
      System.put_env("FORCE_SSL", "")

      config = read_prod_config()

      assert config[:emisar][:public_url][:scheme] == "https"
      assert config[:emisar_web][:force_secure_cookies]
    end

    test "a blank SENTRY_DSN leaves uploads off" do
      System.put_env("SENTRY_DSN", "")

      config = read_prod_config()

      refute Keyword.has_key?(config, :sentry)
    end

    test "a blank MIXPANEL_TOKEN leaves analytics off" do
      System.put_env("MIXPANEL_TOKEN", "")

      config = read_prod_config()

      refute Keyword.has_key?(config[:emisar], :mixpanel_enabled)
    end

    test "a blank X_ADS_CONVERSIONS_JSON boots instead of raising on empty JSON" do
      System.put_env("X_ADS_CONVERSIONS_JSON", "")

      config = read_prod_config()

      refute Keyword.has_key?(config[:emisar], :x_ads_conversions)
    end

    test "a blank optional URL or address is not published as an empty value" do
      System.put_env("STATUS_PAGE_URL", "")
      System.put_env("MAILER_FROM_EMAIL", "")
      System.put_env("POSTMARK_WEBHOOK_SECRET", "")

      config = read_prod_config()

      refute Keyword.has_key?(config[:emisar_web], :status_page_url)
      refute Keyword.has_key?(config[:emisar], :mailer_from_email)
      assert config[:emisar][:postmark_webhook_secret] == nil
    end
  end

  defp read_prod_config do
    Config.Reader.read!(@runtime_config, env: :prod, imports: :disabled)
  end
end
