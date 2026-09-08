defmodule EmisarWeb.AuditPerformanceLiveTest do
  use EmisarWeb.ConnCase, async: true
  alias Emisar.{Audit, Fixtures}

  setup %{conn: conn} do
    {conn, user, account} = register_and_log_in(conn)
    %{conn: conn, user: user, account: account}
  end

  test "event-page navigation and broadcasts reuse open facet choices", %{
    account: account,
    conn: conn
  } do
    seed_choices(account, 55)
    {:ok, lv, _} = live(conn, ~p"/app/#{account}/audit?actor_kind=user")
    observe_queries(lv.pid)
    original = assigns(lv).filter_option_pickers

    lv |> element("#audit-events-pager a", "Next") |> render_click()
    assert assigns(lv).filter_option_pickers == original
    page_queries = queries()
    assert Enum.any?(page_queries, &event_page_query?/1)
    refute Enum.any?(page_queries, &facet_query?/1)

    send(lv.pid, :reload_audit)
    render(lv)
    assert assigns(lv).filter_option_pickers == original
    refute Enum.any?(queries(), &facet_query?/1)

    lv |> element("button[phx-click='toggle_filters']") |> render_click()
    lv |> element("button[phx-click='toggle_filters']") |> render_click()
    assert Enum.any?(queries(), &facet_query?/1)
  end

  test "choice paging and literal search stay bounded without reloading events or patching the URL",
       %{account: account, conn: conn} do
    seed_choices(account, 55)
    selected = Ecto.UUID.generate()
    event(account, selected, "Zürich 100%_\\late")
    {:ok, lv, _} = live(conn, ~p"/app/#{account}/audit?actor_kind=user")
    assert length(assigns(lv).filter_option_pickers.actor_id.options) == 50
    original_events = assigns(lv).events
    original_params = assigns(lv).filter_params
    observe_queries(lv.pid)

    lv |> element("#filter-actor_id-choices button", "Next") |> render_click()
    assert length(assigns(lv).filter_option_pickers.actor_id.options) <= 50
    assert assigns(lv).events == original_events
    assert assigns(lv).filter_params == original_params
    refute Enum.any?(queries(), &event_page_query?/1)

    html = search(lv, "actor_id", "100%_\\")
    assert html =~ ~s(phx-change="search_filter_options")
    assert html =~ ~s(phx-debounce="300")

    assert assigns(lv).filter_option_pickers.actor_id.options == [
             {selected, "Zürich 100%_\\late"}
           ]

    assert assigns(lv).events == original_events
    assert assigns(lv).filter_params == original_params
    search_queries = queries()
    assert Enum.count(search_queries, &facet_query?/1) == 1
    refute Enum.any?(search_queries, &event_page_query?/1)
    refute_patched(lv)

    search(lv, "actor_id", "100%_\\")
    assert queries() == []
    assert search(lv, "actor_id", "no match") =~ "No matching choices."
    refute search(lv, "actor_id", "no match") =~ "Couldn't load choices."
  end

  test "a selected removed identity remains selected while searching, without entering export params",
       %{account: account, conn: conn} do
    id = Ecto.UUID.generate()
    event(account, id, "Former member")
    Fixtures.Accounts.create_subscription(account, "team")
    {:ok, lv, _} = live(conn, ~p"/app/#{account}/audit?actor_kind=user&actor_id=#{id}")
    html = search(lv, "actor_id", "no match")
    assert html =~ "No other matching choices."
    assert has_element?(lv, "input[type='hidden'][name='actor_id'][value='#{id}']")
    assert has_element?(lv, "#filter-actor_id-choices a[aria-current=true]", "Former member")
    assert assigns(lv).filter_params["actor_id"] == id

    render_change(lv, "filter", %{
      "actor_kind" => "user",
      "actor_id" => id,
      "option_search" => %{"actor_id" => "no match"}
    })

    target = assert_patch(lv)
    refute target =~ "option_search"
    refute lv |> element("a[download]") |> render() =~ "option_search"
  end

  test "unavailable selections and failed searches are not presented as All or an empty read", %{
    conn: conn,
    account: account
  } do
    id = Ecto.UUID.generate()

    {:ok, lv, html} =
      live(conn, ~p"/app/#{account}/audit?target_kind=user&target_id=#{id}")

    assert has_element?(lv, "input[type='hidden'][name='target_id'][value='#{id}']")
    assert html =~ "#{id} (unavailable)"
    html = search(lv, "target_id", String.duplicate("x", 513))
    assert html =~ "Search is too long or contains unsupported characters."
    refute html =~ "No matching choices."
    assert has_element?(lv, "input[type='hidden'][name='target_id'][value='#{id}']")
    assert assigns(lv).filter_option_pickers.target_id.search == ""
  end

  test "search refreshes authorization and never returns another account's label", %{
    account: account,
    conn: conn
  } do
    foreign = Fixtures.Accounts.create_account()
    event(foreign, Ecto.UUID.generate(), "Foreign secret")
    event(account, Ecto.UUID.generate(), "Visible local")
    {:ok, lv, _} = live(conn, ~p"/app/#{account}/audit?actor_kind=user")
    refute search(lv, "actor_id", "secret") =~ "Foreign secret"

    :sys.replace_state(
      lv.pid,
      &put_in(
        &1.socket.assigns.current_subject,
        Fixtures.Subjects.permissionless_subject(account)
      )
    )

    search(lv, "actor_id", "Visible")
    assert has_element?(lv, "#filter-actor_id-choices [role='status']", "Couldn't load choices.")
    assert assigns(lv).filter_option_pickers.actor_id.options == []
  end

  test "forged choice events and closed-panel searches do not query or mutate filters", %{
    conn: conn,
    account: account
  } do
    {:ok, lv, _} = live(conn, ~p"/app/#{account}/audit")
    original = assigns(lv).filter_params
    observe_queries(lv.pid)
    search(lv, "actor_id", "anything")
    search(lv, "untrusted", "anything")
    render_click(lv, "page_filter_options", %{"field" => "actor_id", "direction" => "next"})
    render_click(lv, "page_filter_options", %{"field" => "untrusted", "direction" => "next"})

    for malformed <- ["bad", ["bad"], nil] do
      render_change(lv, "search_filter_options", %{
        "_target" => ["option_search", "actor_id"],
        "option_search" => malformed
      })
    end

    assert queries() == []
    assert assigns(lv).filter_params == original
  end

  defp search(lv, field, term) do
    render_change(lv, "search_filter_options", %{
      "_target" => ["option_search", field],
      "option_search" => %{field => term}
    })
  end

  defp seed_choices(account, count) do
    for i <- 1..count do
      event(account, Ecto.UUID.generate(), "Person #{String.pad_leading(to_string(i), 3, "0")}")
    end
  end

  defp event(account, id, label) do
    {:ok, event} =
      Audit.log(account.id, "user.updated",
        actor_kind: "user",
        actor_id: id,
        actor_label: label,
        target_kind: "user",
        target_id: id,
        target_label: label
      )

    event
  end

  defp assigns(lv), do: :sys.get_state(lv.pid).socket.assigns

  defp observe_queries(live_pid) do
    handler = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(
        handler,
        [:emisar, :repo, :query],
        &__MODULE__.query_event/4,
        {self(), live_pid}
      )

    on_exit(fn -> :telemetry.detach(handler) end)
  end

  def query_event(_event, _measurements, metadata, {test_pid, live_pid}) do
    if self() == live_pid, do: send(test_pid, {:identity_query, metadata.query})
  end

  defp queries(acc \\ []) do
    receive do
      {:identity_query, query} -> queries([query | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp facet_query?(query) do
    String.contains?(query, "COLLATE \"C\"") or
      (String.starts_with?(query, "SELECT DISTINCT") and
         String.contains?(query, [".\"actor_kind\"", ".\"target_kind\""]))
  end

  defp event_page_query?(query) do
    [projection | _] = String.split(query, " FROM ", parts: 2)
    String.contains?(projection, "\"payload\"")
  end
end
