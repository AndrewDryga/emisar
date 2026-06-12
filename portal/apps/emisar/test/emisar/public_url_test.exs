defmodule Emisar.PublicUrlTest do
  # async: false — these tests mutate the shared :emisar_web endpoint
  # config to assert how the base URL is derived across environments.
  use ExUnit.Case, async: false

  alias Emisar.PublicUrl

  setup do
    original = Application.get_env(:emisar_web, EmisarWeb.Endpoint, [])
    on_exit(fn -> Application.put_env(:emisar_web, EmisarWeb.Endpoint, original) end)
    :ok
  end

  defp put_url(url_cfg) do
    cfg = Application.get_env(:emisar_web, EmisarWeb.Endpoint, [])
    Application.put_env(:emisar_web, EmisarWeb.Endpoint, Keyword.put(cfg, :url, url_cfg))
  end

  describe "base/0" do
    test "prod-style https host elides the default 443 port" do
      put_url(host: "emisar.dev", port: 443, scheme: "https")
      assert PublicUrl.base() == "https://emisar.dev"
    end

    test "host-only config (dev/config.exs) defaults to http with no port" do
      put_url(host: "localhost")
      assert PublicUrl.base() == "http://localhost"
    end

    test "non-default port is kept" do
      put_url(host: "localhost", port: 4000, scheme: "http")
      assert PublicUrl.base() == "http://localhost:4000"
    end

    test "falls back to http://localhost when no url config exists" do
      Application.put_env(:emisar_web, EmisarWeb.Endpoint, [])
      assert PublicUrl.base() == "http://localhost"
    end
  end

  describe "url/1" do
    test "appends the path to the base, no double slash" do
      put_url(host: "emisar.dev", port: 443, scheme: "https")

      assert PublicUrl.url("/app/settings/billing") ==
               "https://emisar.dev/app/settings/billing"
    end
  end
end
