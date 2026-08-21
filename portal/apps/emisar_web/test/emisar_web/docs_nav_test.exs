defmodule EmisarWeb.DocsNavTest do
  @moduledoc """
  The documentation information architecture is data, and the sidebar, the
  index, the breadcrumbs, prev/next, and the sitemap all read it — so its
  shape and order are pinned here once instead of through page copy.
  """
  use ExUnit.Case, async: true
  alias EmisarWeb.DocsNav

  # The locked IA, top to bottom. Recording it as one list is what makes the
  # flatten, prev/next, and sitemap tests below structural rather than a
  # sample of a few pages.
  @ordered_slugs ~w(
    quickstart
    connect-cli-agent connect-claude-ai connect-chatgpt agents-and-keys bridge-upgrades
    host-install containers kubernetes nomad autoscaling-fleets deployment network-requirements
    authentication teams-and-access
    sso scim integrations-okta integrations-entra integrations-jumpcloud
    integrations-keycloak integrations-google-workspace
    billing
    run-an-action policies-and-approvals signed-dispatch
    runners runs runbooks pack-updates upgrades credentials troubleshooting security-incidents audit-and-siem
    use-a-published-pack action-packs publishing-packs pack-registry
    mcp-reference runner-cli architecture compatibility security-model limits
  )

  describe "groups/0" do
    test "renders the locked top-level groups in order" do
      assert Enum.map(DocsNav.groups(), & &1.label) == [
               "Get started",
               "AI agents",
               "Deploy runners",
               "Team & account",
               "Govern actions",
               "Operate",
               "Action packs",
               "Reference"
             ]
    end

    test "the subgrouped groups declare their display sections in order" do
      subgrouped =
        DocsNav.groups()
        |> Enum.map(fn group -> {group.label, Enum.map(group.sections, & &1.label)} end)
        |> Enum.filter(fn {_label, section_labels} -> Enum.any?(section_labels) end)

      assert subgrouped == [
               {"AI agents", ["Connect", "The fleet"]},
               {"Team & account", ["Access", "Identity concepts", "Provider guides", "Account"]}
             ]
    end

    test "identity concepts and provider walkthroughs are separate sibling sections" do
      sections =
        DocsNav.groups()
        |> Enum.find(&(&1.label == "Team & account"))
        |> Map.fetch!(:sections)

      concepts = Enum.find(sections, &(&1.label == "Identity concepts"))
      providers = Enum.find(sections, &(&1.label == "Provider guides"))

      assert Enum.map(concepts.pages, & &1.slug) == ["sso", "scim"]

      assert Enum.map(providers.pages, & &1.slug) == [
               "integrations-okta",
               "integrations-entra",
               "integrations-jumpcloud",
               "integrations-keycloak",
               "integrations-google-workspace"
             ]
    end

    test "every other group is one unlabelled section, so consumers never special-case a shape" do
      for group <- DocsNav.groups(), group.label not in ["AI agents", "Team & account"] do
        assert [%{label: nil, pages: [_ | _]}] = group.sections
      end
    end

    test "Integrations is gone as a visible group" do
      refute "Integrations" in Enum.map(DocsNav.groups(), & &1.label)
    end
  end

  describe "flat/0" do
    test "flattens groups and sections in display order" do
      assert Enum.map(DocsNav.flat(), & &1.slug) == @ordered_slugs
    end

    test "carries 45 pages with unique slugs and unique /docs paths" do
      pages = DocsNav.flat()
      paths = Enum.map(pages, & &1.path)

      assert length(pages) == 45
      assert pages |> Enum.map(& &1.slug) |> Enum.uniq() |> length() == 45
      assert paths |> Enum.uniq() |> length() == 45
      assert Enum.all?(paths, &String.starts_with?(&1, "/docs/"))
    end

    test "every page carries the copy the index and sidebar render" do
      for page <- DocsNav.flat() do
        assert page.title != ""
        assert String.ends_with?(page.desc, "."), "#{page.slug}: desc is not a sentence"
        assert page[:icon] || page[:logo], "#{page.slug}: neither an icon nor a provider logo"
      end
    end

    test "the provider walkthroughs keep their established /docs/integrations paths" do
      provider_paths =
        DocsNav.flat()
        |> Enum.filter(&String.starts_with?(&1.slug, "integrations-"))
        |> Enum.map(& &1.path)

      assert provider_paths == [
               "/docs/integrations/okta",
               "/docs/integrations/entra",
               "/docs/integrations/jumpcloud",
               "/docs/integrations/keycloak",
               "/docs/integrations/google-workspace"
             ]
    end
  end

  describe "fetch!/1" do
    test "returns the page for a slug" do
      assert %{title: "Manage agents & keys", path: "/docs/agents-and-keys"} =
               DocsNav.fetch!("agents-and-keys")
    end

    test "raises on an unknown slug" do
      assert_raise KeyError, fn -> DocsNav.fetch!("nope") end
    end
  end

  describe "group_label/1" do
    test "returns the top-level group, never the display subgroup" do
      assert DocsNav.group_label("integrations-okta") == "Team & account"
      assert DocsNav.group_label("billing") == "Team & account"
      assert DocsNav.group_label("agents-and-keys") == "AI agents"
      assert DocsNav.group_label("upgrades") == "Operate"
    end

    test "raises on an unknown slug" do
      assert_raise KeyError, fn -> DocsNav.group_label("nope") end
    end
  end

  describe "prev_next/1" do
    test "walks the flattened order across subgroup and group boundaries" do
      assert {%{slug: "teams-and-access"}, %{slug: "scim"}} = DocsNav.prev_next("sso")

      assert {%{slug: "integrations-google-workspace"}, %{slug: "run-an-action"}} =
               DocsNav.prev_next("billing")
    end

    test "the first page has no previous and the last has no next" do
      assert {nil, %{slug: "connect-cli-agent"}} = DocsNav.prev_next(List.first(@ordered_slugs))
      assert {%{slug: "security-model"}, nil} = DocsNav.prev_next(List.last(@ordered_slugs))
    end
  end
end
