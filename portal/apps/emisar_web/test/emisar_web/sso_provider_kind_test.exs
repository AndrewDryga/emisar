defmodule EmisarWeb.SSOProviderKindTest do
  @moduledoc """
  The provider table keeps each guide's `/docs/integrations/…` path as a plain
  string, because Phoenix refuses `~p` inside a module attribute. The router
  check the sigil would have done at compile time happens here instead: every
  named provider deep-links to a docs route that exists, and the one kind
  without a guide says so with `nil` so the console falls back to the generic
  OIDC section.
  """
  use ExUnit.Case, async: true
  alias Emisar.SSO.ProviderKind
  alias EmisarWeb.SSOProviderKind

  test "each named provider deep-links to a docs route that exists" do
    guides =
      ProviderKind.all()
      |> Enum.map(&{&1, SSOProviderKind.docs_path(&1)})
      |> Enum.reject(fn {_kind, path} -> is_nil(path) end)

    assert Enum.map(guides, &elem(&1, 0)) ==
             [:google_workspace, :okta, :entra, :jumpcloud, :keycloak]

    for {kind, path} <- guides do
      route = Phoenix.Router.route_info(EmisarWeb.Router, "GET", path, "")

      assert match?(%{plug: EmisarWeb.MarketingController}, route),
             "#{kind}: #{path} is not a route"
    end
  end

  test "only the generic OIDC kind has no guide to deep-link" do
    assert Enum.reject(ProviderKind.all(), &SSOProviderKind.docs_path/1) == [:openid_connect]
  end
end
