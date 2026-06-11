defmodule EmisarWeb.LiveTableTest do
  @moduledoc """
  `LiveTable.params_to_opts/2` is the deterministic spine — every URL
  param → context-opts translation goes through it, so we pin those.

  Render paths are exercised end-to-end via AuditLive / RunsLive for
  `:table` mode, and via AuthKeysLive / RunbooksLive / AgentsLive /
  ApprovalsLive for `:cards` mode. Here we also smoke-test the cards
  shell directly so the slot+empty+paginator wiring can't regress
  invisibly (the LV tests render the same shell with realistic data
  but with several stylistic layers on top).
  """
  use ExUnit.Case, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias Emisar.Repo.Filter
  alias Emisar.Repo.Paginator.Metadata
  alias EmisarWeb.LiveTable

  defp string_filter(name) do
    %Filter{name: name, type: :string, fun: fn q, _ -> {q, true} end}
  end

  defp list_filter(name, values \\ [{"a", "A"}, {"b", "B"}]) do
    %Filter{
      name: name,
      type: {:list, :string},
      values: values,
      fun: fn q, _ -> {q, true} end
    }
  end

  defp bool_filter(name) do
    %Filter{name: name, type: :boolean, fun: fn q -> {q, true} end}
  end

  describe "params_to_opts/2" do
    test "empty params → empty filter + page opts" do
      assert [filter: [], page: []] = LiveTable.params_to_opts(%{}, [])
    end

    test "ignores unknown param keys" do
      filters = [string_filter(:name)]

      assert [filter: [], page: []] =
               LiveTable.params_to_opts(%{"bogus" => "x"}, filters)
    end

    test "string filters pass through verbatim" do
      filters = [string_filter(:name)]

      assert [filter: [name: "needle"], page: []] =
               LiveTable.params_to_opts(%{"name" => "needle"}, filters)
    end

    test "list filters wrap a single value into a list" do
      filters = [list_filter(:status)]

      assert [filter: [status: ["a"]], page: []] =
               LiveTable.params_to_opts(%{"status" => "a"}, filters)
    end

    test "list filters pass through an already-list value" do
      filters = [list_filter(:status)]

      assert [filter: [status: ["a", "b"]], page: []] =
               LiveTable.params_to_opts(%{"status" => ["a", "b"]}, filters)
    end

    test "boolean filters cast \"true\" / anything-else cleanly" do
      filters = [bool_filter(:archived)]

      assert [filter: [archived: true], page: []] =
               LiveTable.params_to_opts(%{"archived" => "true"}, filters)

      assert [filter: [archived: false], page: []] =
               LiveTable.params_to_opts(%{"archived" => "false"}, filters)
    end

    test "blank string drops the filter (treated as \"not set\")" do
      filters = [string_filter(:name)]

      assert [filter: [], page: []] =
               LiveTable.params_to_opts(%{"name" => ""}, filters)
    end

    test "after cursor lands in page[:cursor]" do
      assert [filter: [], page: [cursor: "abc"]] =
               LiveTable.params_to_opts(%{"after" => "abc"}, [])
    end

    test "before cursor lands in page[:cursor] too — direction is encoded in the cursor blob" do
      assert [filter: [], page: [cursor: "xyz"]] =
               LiveTable.params_to_opts(%{"before" => "xyz"}, [])
    end

    test "after takes precedence when both are present (defensive)" do
      assert [filter: [], page: [cursor: "after-one"]] =
               LiveTable.params_to_opts(%{"after" => "after-one", "before" => "before-one"}, [])
    end

    test "filters + cursor compose into one opts list" do
      filters = [string_filter(:name), list_filter(:status)]

      opts =
        LiveTable.params_to_opts(
          %{"name" => "x", "status" => "a", "after" => "cur"},
          filters
        )

      assert Keyword.get(opts, :filter) == [name: "x", status: ["a"]]
      assert Keyword.get(opts, :page) == [cursor: "cur"]
    end

    test "prefix isolates multi-list pages (e.g. approvals' pending_/grants_/decided_)" do
      filters = [string_filter(:status)]

      params = %{
        "pending_status" => "a",
        "grants_status" => "b",
        "pending_after" => "p-cur"
      }

      pending = LiveTable.params_to_opts(params, filters, prefix: "pending_")
      grants = LiveTable.params_to_opts(params, filters, prefix: "grants_")

      assert Keyword.get(pending, :filter) == [status: "a"]
      assert Keyword.get(pending, :page) == [cursor: "p-cur"]
      assert Keyword.get(grants, :filter) == [status: "b"]
      assert Keyword.get(grants, :page) == []
    end
  end

  describe "live_table :cards render" do
    defp empty_meta, do: %Metadata{previous_page_cursor: nil, next_page_cursor: nil, count: 0}

    test "renders the empty-state block when rows is []" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <LiveTable.live_table
          layout={:cards}
          id="things"
          path="/things"
          rows={[]}
          metadata={empty_meta()}
          filter_params={%{}}
        >
          <:item :let={_t}>
            <li>row</li>
          </:item>
          <:empty>No things yet.</:empty>
        </LiveTable.live_table>
        """)

      assert html =~ ~s(id="things-empty")
      assert html =~ "No things yet."
      # The <ul> shouldn't render in the empty branch.
      refute html =~ ~s(<ul id="things")
    end

    test "renders one <li> per row in the cards <ul>" do
      assigns = %{rows: [%{id: 1, name: "alpha"}, %{id: 2, name: "beta"}]}

      html =
        rendered_to_string(~H"""
        <LiveTable.live_table
          layout={:cards}
          id="things"
          path="/things"
          rows={@rows}
          metadata={%Metadata{count: 2, previous_page_cursor: nil, next_page_cursor: nil}}
          filter_params={%{}}
        >
          <:item :let={t}>
            <li data-name={t.name}>{t.name}</li>
          </:item>
        </LiveTable.live_table>
        """)

      assert html =~ ~s(<ul id="things")
      assert html =~ ~s(data-name="alpha")
      assert html =~ ~s(data-name="beta")
    end

    test "paginator carries the prefix so multi-list pages don't collide" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <LiveTable.live_table
          layout={:cards}
          id="grants"
          path="/approvals"
          prefix="grants_"
          rows={[%{id: 1}]}
          metadata={%Metadata{count: 1, previous_page_cursor: nil, next_page_cursor: "next-cursor"}}
          filter_params={%{}}
        >
          <:item :let={_t}>
            <li>row</li>
          </:item>
        </LiveTable.live_table>
        """)

      assert html =~ "grants_after=next-cursor"
      refute html =~ "after=next-cursor&"
    end

    test "overflow={:visible} drops overflow-hidden so popovers can escape the rounded card" do
      assigns = %{}

      visible =
        rendered_to_string(~H"""
        <LiveTable.live_table
          layout={:cards}
          id="t"
          path="/"
          overflow={:visible}
          rows={[%{id: 1}]}
          metadata={%Metadata{count: 1, previous_page_cursor: nil, next_page_cursor: nil}}
          filter_params={%{}}
        >
          <:item :let={_t}>
            <li>row</li>
          </:item>
        </LiveTable.live_table>
        """)

      hidden =
        rendered_to_string(~H"""
        <LiveTable.live_table
          layout={:cards}
          id="t"
          path="/"
          rows={[%{id: 1}]}
          metadata={%Metadata{count: 1, previous_page_cursor: nil, next_page_cursor: nil}}
          filter_params={%{}}
        >
          <:item :let={_t}>
            <li>row</li>
          </:item>
        </LiveTable.live_table>
        """)

      refute visible =~ "overflow-hidden"
      assert hidden =~ "overflow-hidden"
    end

    test "wrapper_class fully replaces the default <ul> class so different visual layouts (e.g. gapped attention cards) can share the shell" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <LiveTable.live_table
          layout={:cards}
          id="pending"
          path="/"
          wrapper_class="space-y-2 attention-style"
          rows={[%{id: 1}]}
          metadata={%Metadata{count: 1, previous_page_cursor: nil, next_page_cursor: nil}}
          filter_params={%{}}
        >
          <:item :let={_t}>
            <li class="amber">row</li>
          </:item>
        </LiveTable.live_table>
        """)

      assert html =~ ~s(class="space-y-2 attention-style)
      refute html =~ "divide-y divide-zinc-900"
    end

    test "group_by inserts a header before each new label and falls back to a plain text header when :group_header isn't given" do
      assigns = %{
        rows: [
          %{id: 1, group: "prod", name: "alpha"},
          %{id: 2, group: "prod", name: "beta"},
          %{id: 3, group: "stage", name: "gamma"}
        ]
      }

      html =
        rendered_to_string(~H"""
        <LiveTable.live_table
          layout={:cards}
          id="runners"
          path="/runners"
          rows={@rows}
          metadata={%Metadata{count: 3, previous_page_cursor: nil, next_page_cursor: nil}}
          filter_params={%{}}
          group_by={& &1.group}
        >
          <:item :let={r}>
            <li data-name={r.name}>{r.name}</li>
          </:item>
        </LiveTable.live_table>
        """)

      # Default text-only group header renders the label as a <li>
      assert html =~ "prod"
      assert html =~ "stage"
      # Order: header, alpha, beta, then stage header, gamma
      assert String.contains?(html, [
               ~s(data-name="alpha"),
               ~s(data-name="beta"),
               ~s(data-name="gamma")
             ])
    end

    test "custom :group_header slot wins over the default text-only header" do
      assigns = %{rows: [%{id: 1, group: "g1"}, %{id: 2, group: "g2"}]}

      html =
        rendered_to_string(~H"""
        <LiveTable.live_table
          layout={:cards}
          id="t"
          path="/"
          rows={@rows}
          metadata={%Metadata{count: 2, previous_page_cursor: nil, next_page_cursor: nil}}
          filter_params={%{}}
          group_by={& &1.group}
        >
          <:group_header :let={label}>
            <li class="custom-divider">SECTION: {label}</li>
          </:group_header>
          <:item :let={r}>
            <li>{r.id}</li>
          </:item>
        </LiveTable.live_table>
        """)

      assert html =~ "custom-divider"
      assert html =~ "SECTION: g1"
      assert html =~ "SECTION: g2"
    end
  end
end
